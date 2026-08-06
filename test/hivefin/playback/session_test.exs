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

    # Wait for children to clear
    wait_until(fn -> Supervisor.count_sessions() == 0 end, 2_000)

    previous_max = Application.get_env(:hivefin, :max_transcodes)
    previous_hw = Application.get_env(:hivefin, :hw_accel)

    Application.put_env(:hivefin, :hw_accel, :none)

    on_exit(fn ->
      for {id, _} <- Registry.select(Hivefin.Playback.Registry, [{{:"$1", :_, :_}, [], [:"$1"]}]) do
        Session.stop(id)
      end

      if previous_max, do: Application.put_env(:hivefin, :max_transcodes, previous_max)
      if previous_hw, do: Application.put_env(:hivefin, :hw_accel, previous_hw)
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
    info = Session.info(pid)
    assert info.os_pid
    os_pid = info.os_pid
    temp_dir = info.temp_dir

    assert {:ok, :pipe} = Session.await_ready(pid, 15_000)
    assert {:ok, chunk} = Session.read_chunk(pid, 10_000)
    assert byte_size(chunk) > 0
    # MPEG-TS sync byte
    assert :binary.first(chunk) == 0x47 or byte_size(chunk) > 188

    assert :ok = Session.stop(pid)
    refute Process.alive?(pid)

    # FFmpeg OS process should be gone
    wait_until(fn -> not os_pid_alive?(os_pid) end, 3_000)
    refute os_pid_alive?(os_pid)

    # Temp dir cleaned
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

    assert {:ok, :pipe} = Session.await_ready(pid, 20_000)
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

    # Same id is idempotent (not busy)
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
