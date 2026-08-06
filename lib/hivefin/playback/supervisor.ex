defmodule Hivefin.Playback.Supervisor do
  @moduledoc """
  Serializes FFmpeg session starts (atomic concurrency gate) and owns the
  session DynamicSupervisor.

  `start_session/1` returns `{:error, :busy}` when active children reach
  `:max_transcodes` (default 2). Capacity check and child start happen in one
  GenServer call so races cannot exceed the limit.

  During graceful shutdown, `drain/0` rejects new starts and stops all
  sessions so FFmpeg processes receive SIGTERM via `Session.terminate/2`.
  """

  use GenServer

  alias Hivefin.Playback.Session

  @registry Hivefin.Playback.Registry
  @session_sup Hivefin.Playback.SessionSupervisor

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Starts a playback session under the concurrency gate.

  ## attrs
  See `Hivefin.Playback.Session`. Requires `:id`, `:mode`, `:input_path`.

  If a session with the same `:id` is already running **and** its `mode` and
  `input_path` match, returns `{:ok, pid}` of the existing process (idempotent
  reconnect). On identity mismatch the old session is stopped and a new one
  is started so clients cannot reuse a PlaySessionId across media items.
  """
  @spec start_session(map()) :: {:ok, pid()} | {:error, :busy | :draining | term()}
  def start_session(attrs) when is_map(attrs) do
    GenServer.call(__MODULE__, {:start_session, attrs}, 30_000)
  end

  @doc """
  Builds a registry key bound to client play session id + media identity.

  Prevents cross-user / cross-item / cross-mode process sharing when clients
  recycle the same `PlaySessionId` string.
  """
  @spec registry_id(String.t(), keyword() | map()) :: String.t()
  def registry_id(client_play_session_id, identity) when is_binary(client_play_session_id) do
    user_id = identity_get(identity, :user_id) || ""
    media_source_id = identity_get(identity, :media_source_id) || ""
    mode = identity_get(identity, :mode) || ""
    input_path = identity_get(identity, :input_path) || ""

    mode_s =
      case mode do
        m when is_atom(m) -> Atom.to_string(m)
        m when is_binary(m) -> m
        _ -> ""
      end

    path_s = if is_binary(input_path), do: Path.expand(input_path), else: ""

    digest =
      :crypto.hash(
        :sha256,
        [
          client_play_session_id,
          "\0",
          user_id,
          "\0",
          media_source_id,
          "\0",
          mode_s,
          "\0",
          path_s
        ]
      )

    "ps_" <> Base.url_encode64(digest, padding: false)
  end

  @doc """
  Looks up a running session by play session id.
  """
  @spec lookup(String.t()) :: {:ok, pid()} | :error
  def lookup(id) when is_binary(id) do
    case Registry.lookup(@registry, id) do
      [{pid, _}] -> {:ok, pid}
      [] -> :error
    end
  end

  defp identity_get(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp identity_get(list, key) when is_list(list), do: Keyword.get(list, key)
  defp identity_get(_, _), do: nil

  @doc """
  Stops a session by id if present.
  """
  @spec stop_session(String.t()) :: :ok
  def stop_session(id) when is_binary(id) do
    Session.stop(id)
  end

  @doc """
  Number of active FFmpeg sessions.
  """
  @spec count_sessions() :: non_neg_integer()
  def count_sessions do
    case Process.whereis(@session_sup) do
      nil -> 0
      _pid -> DynamicSupervisor.count_children(@session_sup).active
    end
  end

  @doc """
  Reject new sessions and stop all active ones (graceful app shutdown).
  """
  @spec drain() :: :ok
  def drain do
    GenServer.call(__MODULE__, :drain, 15_000)
  catch
    :exit, _ -> :ok
  end

  @doc """
  Configured maximum concurrent sessions (default 2).
  """
  @spec max_transcodes() :: pos_integer()
  def max_transcodes do
    case Application.get_env(:hivefin, :max_transcodes, 2) do
      n when is_integer(n) and n > 0 ->
        n

      n when is_binary(n) ->
        case Integer.parse(n) do
          {i, _} when i > 0 -> i
          _ -> 2
        end

      _ ->
        2
    end
  end

  # GenServer

  @impl true
  def init(_opts) do
    {:ok, _pid} =
      DynamicSupervisor.start_link(
        strategy: :one_for_one,
        name: @session_sup,
        max_restarts: 30,
        max_seconds: 5
      )

    {:ok, %{draining: false}}
  end

  @impl true
  def handle_call({:start_session, _attrs}, _from, %{draining: true} = state) do
    {:reply, {:error, :draining}, state}
  end

  def handle_call({:start_session, attrs}, _from, state) do
    id = Map.fetch!(attrs, :id)
    mode = Map.fetch!(attrs, :mode)
    input_path = attrs |> Map.fetch!(:input_path) |> Path.expand()

    reply =
      case lookup(id) do
        {:ok, pid} ->
          if session_matches?(pid, mode, input_path) do
            {:ok, pid}
          else
            # Same registry id, different media/mode — do not attach.
            Session.stop(pid)
            start_child_session(attrs)
          end

        :error ->
          start_child_session(attrs)
      end

    {:reply, reply, state}
  end

  def handle_call(:drain, _from, state) do
    stop_all_sessions()
    {:reply, :ok, %{state | draining: true}}
  end

  @impl true
  def terminate(_reason, _state) do
    stop_all_sessions()
    :ok
  end

  defp session_matches?(pid, mode, input_path) when is_pid(pid) do
    info = Session.info(pid)
    info.mode == mode and info.input_path == input_path
  catch
    :exit, _ -> false
  end

  defp start_child_session(attrs) do
    if count_sessions() >= max_transcodes() do
      {:error, :busy}
    else
      case DynamicSupervisor.start_child(@session_sup, {Session, attrs}) do
        {:ok, pid} -> {:ok, pid}
        {:error, {:already_started, pid}} -> {:ok, pid}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp stop_all_sessions do
    case Process.whereis(@session_sup) do
      nil ->
        :ok

      sup ->
        DynamicSupervisor.which_children(sup)
        |> Enum.each(fn
          {_, pid, :worker, _} when is_pid(pid) -> Session.stop(pid)
          _ -> :ok
        end)
    end
  end
end
