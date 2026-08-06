defmodule Hivefin.Playback.Session do
  @moduledoc """
  One FFmpeg remux/transcode session under `Hivefin.Playback.Supervisor`.

  ## Modes
  - `:remux` — stream-copy to MPEG-TS on stdout (`pipe:1`)
  - `:transcode` — re-encode; default delivery is progressive MPEG-TS on stdout

  On terminate: SIGTERM/SIGKILL FFmpeg and remove the session temp directory.
  HW encoder init failure retries once with `:libx264` when CPU fallback is allowed.
  """

  use GenServer

  require Logger

  alias Hivefin.Playback.FFmpeg.{Args, ProbeHw, Runner}

  @registry Hivefin.Playback.Registry
  @ready_timeout_ms 15_000
  @chunk_timeout_ms 10_000

  defstruct [
    :id,
    :mode,
    :input_path,
    :encoder,
    :height,
    :temp_dir,
    :port,
    :os_pid,
    :format,
    :playlist_path,
    :status,
    :allow_cpu_fallback,
    :fallback_attempted,
    buffer: <<>>,
    waiters: []
  ]

  @type start_attrs :: %{
          required(:id) => String.t(),
          required(:mode) => :remux | :transcode,
          required(:input_path) => String.t(),
          optional(:encoder) => atom(),
          optional(:height) => pos_integer(),
          optional(:format) => String.t(),
          optional(:allow_cpu_fallback) => boolean()
        }

  # Client API

  def child_spec(attrs) when is_map(attrs) do
    id = Map.fetch!(attrs, :id)

    %{
      id: {:playback_session, id},
      start: {__MODULE__, :start_link, [attrs]},
      restart: :temporary,
      type: :worker,
      shutdown: 5_000
    }
  end

  def start_link(attrs) when is_map(attrs) do
    id = Map.fetch!(attrs, :id)
    GenServer.start_link(__MODULE__, attrs, name: via(id))
  end

  def via(id), do: {:via, Registry, {@registry, id}}

  @doc """
  Waits until the session has produced output (bytes or playlist) or errors.
  """
  @spec await_ready(pid() | String.t(), timeout()) ::
          {:ok, :pipe | :hls} | {:error, term()}
  def await_ready(session, timeout \\ @ready_timeout_ms)

  def await_ready(pid, timeout) when is_pid(pid) do
    GenServer.call(pid, :await_ready, timeout + 100)
  end

  def await_ready(id, timeout) when is_binary(id) do
    GenServer.call(via(id), :await_ready, timeout + 100)
  end

  @doc """
  Reads the next stdout chunk for pipe-mode sessions.
  """
  @spec read_chunk(pid() | String.t(), timeout()) ::
          {:ok, binary()} | {:error, :closed | :timeout | term()}
  def read_chunk(session, timeout \\ @chunk_timeout_ms)

  def read_chunk(pid, timeout) when is_pid(pid) do
    GenServer.call(pid, :read_chunk, timeout + 100)
  end

  def read_chunk(id, timeout) when is_binary(id) do
    GenServer.call(via(id), :read_chunk, timeout + 100)
  end

  @spec info(pid() | String.t()) :: map()
  def info(pid) when is_pid(pid), do: GenServer.call(pid, :info)
  def info(id) when is_binary(id), do: GenServer.call(via(id), :info)

  @spec stop(pid() | String.t()) :: :ok
  def stop(pid) when is_pid(pid) do
    GenServer.stop(pid, :normal, 5_000)
  catch
    :exit, _ -> :ok
  end

  def stop(id) when is_binary(id) do
    case Registry.lookup(@registry, id) do
      [{pid, _}] -> stop(pid)
      [] -> :ok
    end
  end

  # GenServer

  @impl true
  def init(attrs) do
    id = Map.fetch!(attrs, :id)
    mode = Map.fetch!(attrs, :mode)
    input_path = Map.fetch!(attrs, :input_path) |> Path.expand()

    unless File.regular?(input_path) do
      {:stop, :enoent}
    else
      temp_dir = session_temp_dir(id)
      File.mkdir_p!(temp_dir)

      encoder =
        Map.get(attrs, :encoder) ||
          ProbeHw.pick(%{hw_accel: ProbeHw.config_hw_accel()})

      allow_cpu_fallback =
        Map.get(attrs, :allow_cpu_fallback, allow_cpu_fallback_default())

      height = Map.get(attrs, :height, default_height(mode))
      format = Map.get(attrs, :format, "mpegts")

      state = %__MODULE__{
        id: id,
        mode: mode,
        input_path: input_path,
        encoder: encoder,
        height: height,
        temp_dir: temp_dir,
        format: format,
        status: :starting,
        allow_cpu_fallback: allow_cpu_fallback,
        fallback_attempted: false,
        waiters: []
      }

      case start_ffmpeg(state) do
        {:ok, state} ->
          {:ok, %{state | status: :running}}

        {:error, reason} ->
          cleanup_temp(temp_dir)
          {:stop, reason}
      end
    end
  end

  @impl true
  def handle_call(:info, _from, state) do
    {:reply,
     %{
       id: state.id,
       mode: state.mode,
       encoder: state.encoder,
       status: state.status,
       temp_dir: state.temp_dir,
       os_pid: state.os_pid,
       playlist_path: state.playlist_path,
       buffered: byte_size(state.buffer)
     }, state}
  end

  def handle_call(:await_ready, from, state) do
    cond do
      state.status == :failed ->
        {:reply, {:error, :failed}, state}

      state.status == :exited and byte_size(state.buffer) == 0 and is_nil(state.playlist_path) ->
        {:reply, {:error, :exited}, state}

      byte_size(state.buffer) > 0 ->
        {:reply, {:ok, :pipe}, state}

      is_binary(state.playlist_path) and File.regular?(state.playlist_path) ->
        {:reply, {:ok, :hls}, state}

      true ->
        {:noreply, %{state | waiters: [{:ready, from} | state.waiters]}}
    end
  end

  def handle_call(:read_chunk, from, state) do
    cond do
      byte_size(state.buffer) > 0 ->
        {chunk, rest} = take_chunk(state.buffer)
        {:reply, {:ok, chunk}, %{state | buffer: rest}}

      state.status in [:exited, :failed] ->
        {:reply, {:error, :closed}, state}

      true ->
        {:noreply, %{state | waiters: [{:chunk, from} | state.waiters]}}
    end
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) when is_binary(data) do
    state = %{state | buffer: state.buffer <> data}
    state = notify_waiters(state)
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.debug(
      "FFmpeg session #{state.id} exited with status #{status} encoder=#{state.encoder}"
    )

    state = %{state | port: nil, status: if(status == 0, do: :exited, else: :failed)}

    cond do
      status != 0 and should_fallback?(state) ->
        Logger.info(
          "HW encoder #{state.encoder} failed for session #{state.id}; falling back to libx264"
        )

        fallback_restart(state)

      true ->
        state = notify_waiters_closed(state)
        # Keep GenServer alive briefly so clients can drain buffer / read info.
        {:noreply, state}
    end
  end

  def handle_info(:poll_playlist, state) do
    cond do
      is_binary(state.playlist_path) and File.regular?(state.playlist_path) ->
        {ready, rest} =
          Enum.split_with(state.waiters, fn
            {:ready, _} -> true
            _ -> false
          end)

        Enum.each(ready, fn {:ready, from} -> GenServer.reply(from, {:ok, :hls}) end)
        {:noreply, %{state | waiters: rest}}

      state.status in [:exited, :failed] ->
        {:noreply, notify_waiters_closed(state)}

      true ->
        Process.send_after(self(), :poll_playlist, 150)
        {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.port, do: Runner.kill(state.port)
    if state.os_pid, do: Runner.kill(state.os_pid)
    cleanup_temp(state.temp_dir)
    :ok
  end

  # Internals

  defp start_ffmpeg(%{mode: :remux} = state) do
    args =
      Args.remux(state.input_path, %{
        output: "pipe:1",
        format: "mpegts"
      })

    open_port(state, args)
  end

  defp start_ffmpeg(%{mode: :transcode, format: "hls"} = state) do
    playlist = Path.join(state.temp_dir, "index.m3u8")
    segment_pattern = Path.join(state.temp_dir, "seg_%03d.ts")

    args =
      Args.transcode(state.input_path, %{
        encoder: state.encoder,
        output: playlist,
        format: "hls",
        hls_segment_pattern: segment_pattern,
        height: state.height
      })

    case open_port(state, args) do
      {:ok, state} ->
        # Poll for playlist appearance (HLS writes files, little/no stdout).
        Process.send_after(self(), :poll_playlist, 100)
        {:ok, %{state | playlist_path: playlist}}

      error ->
        error
    end
  end

  defp start_ffmpeg(%{mode: :transcode} = state) do
    args =
      Args.transcode(state.input_path, %{
        encoder: state.encoder,
        output: "pipe:1",
        format: "mpegts",
        height: state.height
      })

    open_port(state, args)
  end

  defp open_port(state, args) do
    case Runner.open(args) do
      {:ok, port} ->
        os_pid = Runner.os_pid(port)
        {:ok, %{state | port: port, os_pid: os_pid}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp should_fallback?(state) do
    state.encoder != :libx264 and state.allow_cpu_fallback and not state.fallback_attempted
  end

  defp fallback_restart(state) do
    if state.port, do: Runner.close(state.port)

    state = %{
      state
      | encoder: :libx264,
        fallback_attempted: true,
        port: nil,
        os_pid: nil,
        status: :starting,
        buffer: <<>>
    }

    case start_ffmpeg(state) do
      {:ok, state} ->
        {:noreply, %{state | status: :running}}

      {:error, reason} ->
        state = %{state | status: :failed}
        state = reply_all_waiters(state, {:error, reason})
        {:noreply, state}
    end
  end

  defp notify_waiters(state) do
    {ready, rest} =
      Enum.split_with(state.waiters, fn
        {:ready, _} -> true
        _ -> false
      end)

    Enum.each(ready, fn {:ready, from} ->
      GenServer.reply(from, {:ok, :pipe})
    end)

    {chunks, rest2} =
      Enum.split_with(rest, fn
        {:chunk, _} -> true
        _ -> false
      end)

    {state, remaining_chunk_waiters} =
      Enum.reduce(chunks, {state, []}, fn {:chunk, from}, {st, leftover} ->
        if byte_size(st.buffer) > 0 do
          {chunk, rest_buf} = take_chunk(st.buffer)
          GenServer.reply(from, {:ok, chunk})
          {%{st | buffer: rest_buf}, leftover}
        else
          {st, [{:chunk, from} | leftover]}
        end
      end)

    %{state | waiters: remaining_chunk_waiters ++ rest2}
  end

  defp notify_waiters_closed(state) do
    Enum.each(state.waiters, fn
      {:ready, from} ->
        if byte_size(state.buffer) > 0 do
          GenServer.reply(from, {:ok, :pipe})
        else
          GenServer.reply(from, {:error, :exited})
        end

      {:chunk, from} ->
        if byte_size(state.buffer) > 0 do
          # Leave buffer for subsequent read_chunk calls; wake one waiter with data via notify
          :ok
        else
          GenServer.reply(from, {:error, :closed})
        end
    end)

    # Re-notify chunk waiters that can take remaining buffer
    state = %{state | waiters: Enum.filter(state.waiters, &match?({:chunk, _}, &1))}
    notify_waiters(state)
  end

  defp reply_all_waiters(state, reply) do
    Enum.each(state.waiters, fn {_, from} -> GenServer.reply(from, reply) end)
    %{state | waiters: []}
  end

  defp take_chunk(buffer) when byte_size(buffer) > 65_536 do
    <<chunk::binary-size(65_536), rest::binary>> = buffer
    {chunk, rest}
  end

  defp take_chunk(buffer), do: {buffer, <<>>}

  defp session_temp_dir(id) do
    base =
      Application.get_env(:hivefin, :transcode_dir) ||
        Path.join(System.tmp_dir!(), "hivefin-transcode")

    Path.join(base, sanitize_id(id))
  end

  defp sanitize_id(id) do
    id
    |> String.replace(~r/[^A-Za-z0-9._-]/, "_")
    |> String.slice(0, 120)
  end

  defp cleanup_temp(nil), do: :ok

  defp cleanup_temp(dir) when is_binary(dir) do
    if String.contains?(dir, "hivefin") or String.contains?(dir, "transcode") do
      File.rm_rf(dir)
    end

    :ok
  rescue
    _ -> :ok
  end

  defp default_height(:transcode), do: 720
  defp default_height(:remux), do: nil

  defp allow_cpu_fallback_default do
    case Application.get_env(:hivefin, :allow_cpu_fallback, true) do
      false -> false
      "false" -> false
      "0" -> false
      _ -> true
    end
  end
end
