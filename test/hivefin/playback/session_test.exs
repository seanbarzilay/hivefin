defmodule Hivefin.Playback.SessionTest do
  use ExUnit.Case, async: false

  alias Hivefin.Playback.{Session, Supervisor}

  @fixture Path.expand(
             "test/support/fixtures/media_tree/movies/Big Buck Bunny (2008)/Big Buck Bunny (2008).mp4",
             File.cwd!()
           )

  setup do
    # Drain leftover sessions from other tests
    for {id, _} <- Registry.select(Hivefin.Playback.Registry, [{{:"$1", :_, :_}, [], [:"$1"]}]) do
      Session.stop(id)
    end

    wait_until(fn -> Supervisor.count_sessions() == 0 end, 2_000)

    previous_max = Application.get_env(:hivefin, :max_transcodes)
    previous_hw = Application.get_env(:hivefin, :hw_accel)
    previous_idle = Application.get_env(:hivefin, :session_idle_ms)

    Application.put_env(:hivefin, :hw_accel, :none)

    on_exit(fn ->
      for {id, _} <- Registry.select(Hivefin.Playback.Registry, [{{:"$1", :_, :_}, [], [:"$1"]}]) do
        Session.stop(id)
      end

      if previous_max, do: Application.put_env(:hivefin, :max_transcodes, previous_max)
      if previous_hw, do: Application.put_env(:hivefin, :hw_accel, previous_hw)
      if previous_idle, do: Application.put_env(:hivefin, :session_idle_ms, previous_idle)
    end)

    :ok
  end

  @tag :ffmpeg
  test "remux session produces MPEG-TS bytes and cleans up on stop" do
    id = "test-remux-#{System.unique_integer([:positive])}"

    assert {:ok, pid} =
             Supervisor.start_session(%{
               id: id,
               mode: :remux,
               input_path: @fixture
             })

    assert Process.alive?(pid)
    :ok = Session.attach_consumer(pid, self())
    info = Session.info(pid)
    assert info.os_pid
    os_pid = info.os_pid
    temp_dir = info.temp_dir

    assert {:ok, :pipe} = Session.await_ready(pid, 15_000)
    assert {:ok, chunk} = Session.read_chunk(pid, 10_000)
    assert byte_size(chunk) > 0
    # MPEG-TS sync byte
    assert :binary.first(chunk) == 0x47 or byte_size(chunk) > 188

    # stderr must not be mixed into media — no ffmpeg log text in TS body
    refute chunk =~ "ffmpeg"
    refute chunk =~ "Error"
    refute chunk =~ "encoder"

    assert :ok = Session.stop(pid)
    refute Process.alive?(pid)

    wait_until(fn -> not os_pid_alive?(os_pid) end, 3_000)
    refute os_pid_alive?(os_pid)

    wait_until(fn -> not File.dir?(temp_dir) end, 2_000)
    refute File.dir?(temp_dir)
  end

  @tag :ffmpeg
  test "transcode session with libx264 produces output" do
    id = "test-xcode-#{System.unique_integer([:positive])}"

    assert {:ok, pid} =
             Supervisor.start_session(%{
               id: id,
               mode: :transcode,
               input_path: @fixture,
               encoder: :libx264,
               height: 240
             })

    Session.attach_consumer(pid, self())
    assert {:ok, :pipe} = Session.await_ready(pid, 20_000)
    assert {:ok, chunk} = Session.read_chunk(pid, 15_000)
    assert byte_size(chunk) > 100
    refute chunk =~ "libx264"

    info = Session.info(pid)
    assert info.encoder == :libx264

    Session.stop(pid)
  end

  @tag :ffmpeg
  test "HW encoder failure falls back to libx264" do
    id = "test-fallback-#{System.unique_integer([:positive])}"

    # h264_nvenc fails quickly on hosts without NVIDIA; session must retry libx264.
    assert {:ok, pid} =
             Supervisor.start_session(%{
               id: id,
               mode: :transcode,
               input_path: @fixture,
               encoder: :nvenc,
               height: 240,
               allow_cpu_fallback: true
             })

    Session.attach_consumer(pid, self())
    assert {:ok, :pipe} = Session.await_ready(pid, 25_000)
    assert {:ok, chunk} = Session.read_chunk(pid, 15_000)
    assert byte_size(chunk) > 100

    info = Session.info(pid)
    assert info.encoder == :libx264

    Session.stop(pid)
  end

  @tag :ffmpeg
  test "concurrency: second session is busy when max is 1" do
    Application.put_env(:hivefin, :max_transcodes, 1)

    id1 = "test-busy-1-#{System.unique_integer([:positive])}"
    id2 = "test-busy-2-#{System.unique_integer([:positive])}"

    assert {:ok, pid1} =
             Supervisor.start_session(%{
               id: id1,
               mode: :remux,
               input_path: @fixture
             })

    assert {:error, :busy} =
             Supervisor.start_session(%{
               id: id2,
               mode: :remux,
               input_path: @fixture
             })

    assert {:ok, ^pid1} =
             Supervisor.start_session(%{
               id: id1,
               mode: :remux,
               input_path: @fixture
             })

    Session.stop(pid1)
    wait_until(fn -> Supervisor.count_sessions() == 0 end, 2_000)

    assert {:ok, pid2} =
             Supervisor.start_session(%{
               id: id2,
               mode: :remux,
               input_path: @fixture
             })

    Session.stop(pid2)
  end

  @tag :ffmpeg
  test "session idles out after consumers leave" do
    Application.put_env(:hivefin, :session_idle_ms, 200)

    id = "test-idle-#{System.unique_integer([:positive])}"

    assert {:ok, pid} =
             Supervisor.start_session(%{
               id: id,
               mode: :remux,
               input_path: @fixture
             })

    consumer =
      spawn(fn ->
        Session.attach_consumer(pid, self())
        receive do: (:go -> :ok)
      end)

    wait_until(fn -> Session.info(pid).consumers >= 1 end, 1_000)
    send(consumer, :go)
    wait_until(fn -> not Process.alive?(consumer) end, 1_000)

    # Idle reap
    wait_until(fn -> not Process.alive?(pid) end, 3_000)
    refute Process.alive?(pid)
    assert Supervisor.count_sessions() == 0
  end

  @tag :ffmpeg
  test "killed consumer reclaims slot even while FFmpeg still producing" do
    # Short idle; media/port activity must not refresh the countdown.
    Application.put_env(:hivefin, :session_idle_ms, 300)

    id = "test-idle-kill-#{System.unique_integer([:positive])}"

    assert {:ok, pid} =
             Supervisor.start_session(%{
               id: id,
               mode: :transcode,
               input_path: @fixture,
               encoder: :libx264,
               height: 240
             })

    parent = self()

    consumer =
      spawn(fn ->
        Session.attach_consumer(pid, self())
        send(parent, :attached)
        # Stay alive until killed — simulates HTTP process dying with :kill
        # (no try/after Session.stop).
        Process.sleep(:infinity)
      end)

    assert_receive :attached, 1_000
    assert {:ok, :pipe} = Session.await_ready(pid, 20_000)
    assert {:ok, _chunk} = Session.read_chunk(pid, 10_000)

    # Brutal consumer death (no cooperative stop)
    Process.exit(consumer, :kill)
    wait_until(fn -> not Process.alive?(consumer) end, 1_000)

    # Polling info/activity while unattended must not keep the session alive.
    started = System.monotonic_time(:millisecond)

    wait_until(
      fn ->
        if Process.alive?(pid) do
          try do
            _ = Session.info(pid)
          catch
            :exit, _ -> :ok
          end
        end

        not Process.alive?(pid)
      end,
      2_000
    )

    elapsed = System.monotonic_time(:millisecond) - started
    refute Process.alive?(pid)
    assert Supervisor.count_sessions() == 0
    # Should exit on idle (~300ms), not wait for full encode; allow slack.
    assert elapsed < 1_500
  end

  test "start_session rejects missing input" do
    id = "test-missing-#{System.unique_integer([:positive])}"

    assert {:error, :enoent} =
             Supervisor.start_session(%{
               id: id,
               mode: :remux,
               input_path: "/tmp/hivefin-does-not-exist-#{System.unique_integer()}.mp4"
             })
  end

  defp os_pid_alive?(os_pid) when is_integer(os_pid) do
    case System.cmd("kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  end

  defp os_pid_alive?(_), do: false

  defp wait_until(fun, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait(fun, deadline)
  end

  defp do_wait(fun, deadline) do
    if fun.() do
      true
    else
      if System.monotonic_time(:millisecond) >= deadline do
        false
      else
        Process.sleep(50)
        do_wait(fun, deadline)
      end
    end
  end
end
