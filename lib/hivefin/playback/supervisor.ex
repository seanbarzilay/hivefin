defmodule Hivefin.Playback.Supervisor do
  @moduledoc """
  DynamicSupervisor for FFmpeg playback sessions plus concurrency gate.

  `start_session/1` returns `{:error, :busy}` when active children reach
  `:max_transcodes` (default 2).
  """

  use DynamicSupervisor

  alias Hivefin.Playback.Session

  @registry Hivefin.Playback.Registry

  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one, max_restarts: 30, max_seconds: 5)
  end

  @doc """
  Starts a playback session.

  ## attrs
  See `Hivefin.Playback.Session`. Requires `:id`, `:mode`, `:input_path`.

  If a session with the same `:id` is already running, returns `{:ok, pid}`
  of the existing process (idempotent for reconnecting clients).
  """
  @spec start_session(map()) :: {:ok, pid()} | {:error, :busy | term()}
  def start_session(attrs) when is_map(attrs) do
    id = Map.fetch!(attrs, :id)

    case lookup(id) do
      {:ok, pid} ->
        {:ok, pid}

      :error ->
        if at_capacity?() do
          {:error, :busy}
        else
          child_spec = {Session, attrs}

          case DynamicSupervisor.start_child(__MODULE__, child_spec) do
            {:ok, pid} ->
              {:ok, pid}

            {:error, {:already_started, pid}} ->
              {:ok, pid}

            {:error, reason} ->
              {:error, reason}
          end
        end
    end
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
    DynamicSupervisor.count_children(__MODULE__).active
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

  defp at_capacity? do
    count_sessions() >= max_transcodes()
  end
end
