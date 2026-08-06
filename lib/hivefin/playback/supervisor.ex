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

  If a session with the same `:id` is already running, returns `{:ok, pid}`
  of the existing process (idempotent for reconnecting clients).
  """
  @spec start_session(map()) :: {:ok, pid()} | {:error, :busy | :draining | term()}
  def start_session(attrs) when is_map(attrs) do
    GenServer.call(__MODULE__, {:start_session, attrs}, 30_000)
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

    reply =
      case lookup(id) do
        {:ok, pid} ->
          {:ok, pid}

        :error ->
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
