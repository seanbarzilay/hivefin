defmodule Hivefin.Playback.Session do
  @moduledoc """
  One FFmpeg remux/transcode session under `Hivefin.Playback.Supervisor`.

  ## Modes
  - `:remux` — stream-copy to MPEG-TS on stdout (`pipe:1`)
  - `:transcode` — re-encode; progressive MPEG-TS on stdout

  ## Lifecycle
  - Monitors HTTP consumer processes (`attach_consumer/2`); last consumer exit
    starts idle countdown.
  - Self-stops after configurable idle with no consumers (`:session_idle_ms`,
    default 60s).
  - Waiter timeouts are tracked server-side so GenServer.call timeouts do not
    leave orphaned waiters; clients should still `stop/1` on their own timeout.
  - On terminate: SIGTERM/SIGKILL FFmpeg and remove temp dir **only if under**
    configured `:transcode_dir`.
  - HW encoder exit failure retries once with `:libx264` when CPU fallback allowed.
  """

  use GenServer

  require Logger

  alias Hivefin.Playback.FFmpeg.{Args, ProbeHw, Runner}

  @registry Hivefin.Playback.Registry
  @ready_timeout_ms 15_000
  @chunk_timeout_ms 10_000
  @default_idle_ms 60_000

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
    :idle_timer,
    buffer: <<>>,
    waiters: [],
    consumers: %{},
    last_activity_ms: 0
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
  Registers the HTTP (or other) consumer process. Session monitors it and
  idles out after the last consumer exits.
  """
  @spec attach_consumer(pid() | String.t(), pid()) :: :ok
  def attach_consumer(session, consumer \\ self())

  def attach_consumer(pid, consumer) when is_pid(pid) and is_pid(consumer) do
    GenServer.call(pid, {:attach_consumer, consumer})
  end

  def attach_consumer(id, consumer) when is_binary(id) and is_pid(consumer) do
    GenServer.call(via(id), {:attach_consumer, consumer})
  end

  @doc """
  Waits until the session has produced output or errors.

  On client-side call timeout the session is stopped so slots are not held.
  """
  @spec await_ready(pid() | String.t(), timeout()) ::
          {:ok, :pipe | :hls} | {:error, term()}
  def await_ready(session, timeout \\ @ready_timeout_ms)

  def await_ready(pid, timeout) when is_pid(pid) do
    call_with_orphan_guard(pid, {:await_ready, timeout}, timeout)
  end

  def await_ready(id, timeout) when is_binary(id) do
    call_with_orphan_guard(via(id), {:await_ready, timeout}, timeout)
  end

  @doc """
  Reads the next stdout chunk for pipe-mode sessions.

  On client-side call timeout the session is stopped (no progress path).
  """
  @spec read_chunk(pid() | String.t(), timeout()) ::
          {:ok, binary()} | {:error, :closed | :timeout | term()}
  def read_chunk(session, timeout \\ @chunk_timeout_ms)

  def read_chunk(pid, timeout) when is_pid(pid) do
    call_with_orphan_guard(pid, {:read_chunk, timeout}, timeout)
  end

  def read_chunk(id, timeout) when is_binary(id) do
    call_with_orphan_guard(via(id), {:read_chunk, timeout}, timeout)
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

  defp call_with_orphan_guard(dest, request, timeout) do
    GenServer.call(dest, request, timeout + 500)
  catch
    :exit, {:timeout, _} ->
      stop_dest(dest)
      {:error, :timeout}

    :exit, {:noproc, _} ->
      {:error, :noproc}

    :exit, reason ->
      stop_dest(dest)
      {:error, reason}
  end

  defp stop_dest(pid) when is_pid(pid), do: stop(pid)
  defp stop_dest({:via, Registry, {@registry, id}}), do: stop(id)
  defp stop_dest(_), do: :ok

  # GenServer

  @impl true
  def init(attrs) do
    id = Map.fetch!(attrs, :id)
    mode = Map.fetch!(attrs, :mode)
    input_path = Map.fetch!(attrs, :input_path) |> Path.expand()

    unless File.regular?(input_path) do
      {:stop, :enoent}
    else
      allow_cpu_fallback =
        Map.get(attrs, :allow_cpu_fallback, allow_cpu_fallback_default())

      encoder_result =
        case Map.fetch(attrs, :encoder) do
          {:ok, enc} ->
            {:ok, enc}

          :error ->
            ProbeHw.pick(%{
              hw_accel: ProbeHw.config_hw_accel(),
              allow_cpu_fallback: allow_cpu_fallback
            })
        end

      case encoder_result do
        {:error, reason} ->
          {:stop, reason}

        {:ok, encoder} ->
          temp_dir = session_temp_dir(id)
          File.mkdir_p!(temp_dir)

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
            waiters: [],
            consumers: %{},
            last_activity_ms: now_ms()
          }

          case start_ffmpeg(state) do
            {:ok, state} ->
              state = schedule_idle(state)
              {:ok, %{state | status: :running}}

            {:error, reason} ->
              cleanup_temp(temp_dir)
              {:stop, reason}
          end
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
       buffered: byte_size(state.buffer),
       consumers: map_size(state.consumers)
     }, touch(state)}
  end

  def handle_call({:attach_consumer, consumer}, _from, state) do
    ref = Process.monitor(consumer)
    consumers = Map.put(state.consumers, ref, consumer)
    state = cancel_idle(%{state | consumers: consumers})
    {:reply, :ok, touch(state)}
  end

  def handle_call({:await_ready, timeout}, from, state) do
    cond do
      state.status == :failed ->
        {:reply, {:error, :failed}, state}

      state.status == :exited and byte_size(state.buffer) == 0 and is_nil(state.playlist_path) ->
        {:reply, {:error, :exited}, state}

      byte_size(state.buffer) > 0 ->
        {:reply, {:ok, :pipe}, touch(state)}

      is_binary(state.playlist_path) and File.regular?(state.playlist_path) ->
        {:reply, {:ok, :hls}, touch(state)}

      true ->
        tref = Process.send_after(self(), {:waiter_timeout, from}, timeout)
        waiter = {:ready, from, tref}
        {:noreply, touch(%{state | waiters: [waiter | state.waiters]})}
    end
  end

  def handle_call({:read_chunk, timeout}, from, state) do
    cond do
      byte_size(state.buffer) > 0 ->
        {chunk, rest} = take_chunk(state.buffer)
        {:reply, {:ok, chunk}, touch(%{state | buffer: rest})}

      state.status in [:exited, :failed] ->
        {:reply, {:error, :closed}, state}

      true ->
        tref = Process.send_after(self(), {:waiter_timeout, from}, timeout)
        waiter = {:chunk, from, tref}
        {:noreply, touch(%{state | waiters: [waiter | state.waiters]})}
    end
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) when is_binary(data) do
    state = %{state | buffer: state.buffer <> data}
    state = notify_waiters(state)
    {:noreply, touch(state)}
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
        # Keep GenServer alive so consumers can drain buffer; idle timer reaps.
        {:noreply, schedule_idle(touch(state))}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    consumers = Map.delete(state.consumers, ref)
    state = %{state | consumers: consumers}

    state =
      if map_size(consumers) == 0 do
        schedule_idle(state)
      else
        state
      end

    {:noreply, state}
  end

  def handle_info({:waiter_timeout, from}, state) do
    {matching, rest} =
      Enum.split_with(state.waiters, fn
        {_kind, ^from, _tref} -> true
        _ -> false
      end)

    Enum.each(matching, fn {_kind, f, tref} ->
      Process.cancel_timer(tref)
      GenServer.reply(f, {:error, :timeout})
    end)

    state = %{state | waiters: rest}

    # No progress for this waiter — if nobody is attached, shut down so the
    # concurrency slot is released.
    state =
      if map_size(state.consumers) == 0 and rest == [] do
        {:stop, :timeout, state}
      else
        {:noreply, schedule_idle(state)}
      end

    state
  end

  def handle_info(:idle_timeout, state) do
    if map_size(state.consumers) == 0 and state.waiters == [] do
      Logger.debug("Playback session #{state.id} idle timeout; stopping")
      {:stop, :normal, %{state | idle_timer: nil}}
    else
      {:noreply, schedule_idle(%{state | idle_timer: nil})}
    end
  end

  def handle_info(:poll_playlist, state) do
    cond do
      is_binary(state.playlist_path) and File.regular?(state.playlist_path) ->
        state = reply_ready_waiters(state, :hls)
        {:noreply, touch(state)}

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
    reply_all_waiters(state, {:error, :closed})
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
        {:noreply, touch(%{state | status: :running})}

      {:error, reason} ->
        state = %{state | status: :failed}
        state = reply_all_waiters(state, {:error, reason})
        {:noreply, schedule_idle(state)}
    end
  end

  defp notify_waiters(state) do
    {ready, rest} =
      Enum.split_with(state.waiters, fn
        {:ready, _, _} -> true
        _ -> false
      end)

    Enum.each(ready, fn {:ready, from, tref} ->
      Process.cancel_timer(tref)
      GenServer.reply(from, {:ok, :pipe})
    end)

    {chunks, rest2} =
      Enum.split_with(rest, fn
        {:chunk, _, _} -> true
        _ -> false
      end)

    {state, remaining_chunk_waiters} =
      Enum.reduce(chunks, {state, []}, fn {:chunk, from, tref}, {st, leftover} ->
        if byte_size(st.buffer) > 0 do
          Process.cancel_timer(tref)
          {chunk, rest_buf} = take_chunk(st.buffer)
          GenServer.reply(from, {:ok, chunk})
          {%{st | buffer: rest_buf}, leftover}
        else
          {st, [{:chunk, from, tref} | leftover]}
        end
      end)

    %{state | waiters: remaining_chunk_waiters ++ rest2}
  end

  defp reply_ready_waiters(state, kind) do
    {ready, rest} =
      Enum.split_with(state.waiters, fn
        {:ready, _, _} -> true
        _ -> false
      end)

    Enum.each(ready, fn {:ready, from, tref} ->
      Process.cancel_timer(tref)
      GenServer.reply(from, {:ok, kind})
    end)

    %{state | waiters: rest}
  end

  defp notify_waiters_closed(state) do
    {with_data_chunks, closed} =
      Enum.split_with(state.waiters, fn
        {:chunk, _, _} -> byte_size(state.buffer) > 0
        {:ready, _, _} -> byte_size(state.buffer) > 0
        _ -> false
      end)

    # Ready waiters with buffered data succeed as pipe.
    Enum.each(with_data_chunks, fn
      {:ready, from, tref} ->
        Process.cancel_timer(tref)
        GenServer.reply(from, {:ok, :pipe})

      {:chunk, _from, _tref} ->
        :ok
    end)

    # Keep chunk waiters that can still drain buffer
    chunk_waiters =
      Enum.filter(with_data_chunks, fn
        {:chunk, _, _} -> true
        _ -> false
      end)

    Enum.each(closed, fn
      {:ready, from, tref} ->
        Process.cancel_timer(tref)
        GenServer.reply(from, {:error, :exited})

      {:chunk, from, tref} ->
        Process.cancel_timer(tref)
        GenServer.reply(from, {:error, :closed})
    end)

    state = %{state | waiters: chunk_waiters}
    notify_waiters(state)
  end

  defp reply_all_waiters(state, reply) do
    Enum.each(state.waiters, fn {_kind, from, tref} ->
      Process.cancel_timer(tref)
      GenServer.reply(from, reply)
    end)

    %{state | waiters: []}
  end

  defp take_chunk(buffer) when byte_size(buffer) > 65_536 do
    <<chunk::binary-size(65_536), rest::binary>> = buffer
    {chunk, rest}
  end

  defp take_chunk(buffer), do: {buffer, <<>>}

  defp session_temp_dir(id) do
    Path.join(transcode_base(), sanitize_id(id))
  end

  defp transcode_base do
    base =
      Application.get_env(:hivefin, :transcode_dir) ||
        Path.join(System.tmp_dir!(), "hivefin-transcode")

    Path.expand(base)
  end

  defp sanitize_id(id) do
    id
    |> String.replace(~r/[^A-Za-z0-9._-]/, "_")
    |> String.slice(0, 120)
  end

  defp cleanup_temp(nil), do: :ok

  defp cleanup_temp(dir) when is_binary(dir) do
    base = transcode_base()
    expanded = Path.expand(dir)

    if under_base?(base, expanded) do
      File.rm_rf(expanded)
    else
      Logger.warning("Refusing to delete temp dir outside transcode base: #{expanded}")
    end

    :ok
  rescue
    _ -> :ok
  end

  defp under_base?(base, path) do
    base = String.trim_trailing(base, "/")
    path == base or String.starts_with?(path, base <> "/")
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

  defp idle_ms do
    case Application.get_env(:hivefin, :session_idle_ms, @default_idle_ms) do
      n when is_integer(n) and n > 0 -> n
      _ -> @default_idle_ms
    end
  end

  defp schedule_idle(state) do
    state = cancel_idle(state)

    if map_size(state.consumers) == 0 and state.waiters == [] do
      tref = Process.send_after(self(), :idle_timeout, idle_ms())
      %{state | idle_timer: tref}
    else
      state
    end
  end

  defp cancel_idle(%{idle_timer: tref} = state) when is_reference(tref) do
    Process.cancel_timer(tref)
    %{state | idle_timer: nil}
  end

  defp cancel_idle(state), do: %{state | idle_timer: nil}

  defp touch(state) do
    state = %{state | last_activity_ms: now_ms()}
    # Activity with consumers/waiters: no idle. Without them, reschedule.
    if map_size(state.consumers) == 0 and state.waiters == [] do
      schedule_idle(state)
    else
      cancel_idle(state)
    end
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
