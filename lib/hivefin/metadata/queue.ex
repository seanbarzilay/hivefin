defmodule Hivefin.Metadata.Queue do
  @moduledoc """
  Bounded queue for post-scan metadata refreshes.

  Scanning used to spawn one Task per new item, which stampeded the rate
  limiter (30s call timeouts → `:rate_limited` noise) and hammered TMDB.
  This process keeps a FIFO queue and runs at most `max_concurrency` workers.
  """

  use GenServer

  require Logger

  alias Hivefin.Metadata.Worker

  @default_max 2

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Enqueue an item id for metadata refresh (async, best-effort).
  """
  def enqueue(item_id, server \\ __MODULE__) when is_binary(item_id) do
    GenServer.cast(server, {:enqueue, item_id})
  end

  @impl true
  def init(opts) do
    max =
      Keyword.get(opts, :max_concurrency) ||
        Application.get_env(:hivefin, :metadata_max_concurrency, @default_max)

    max = if is_integer(max) and max > 0, do: max, else: @default_max

    {:ok,
     %{
       queue: :queue.new(),
       busy: 0,
       max: max,
       # ref => item_id
       workers: %{}
     }}
  end

  @impl true
  def handle_cast({:enqueue, item_id}, state) do
    state = %{state | queue: :queue.in(item_id, state.queue)}
    {:noreply, pump(state)}
  end

  @impl true
  def handle_info({ref, _result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    state = finish_worker(state, ref)
    {:noreply, pump(state)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    if reason not in [:normal, :noproc] do
      item_id = Map.get(state.workers, ref, "?")
      Logger.warning("metadata worker died for #{item_id}: #{inspect(reason)}")
    end

    state = finish_worker(state, ref)
    {:noreply, pump(state)}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp finish_worker(state, ref) do
    workers = Map.delete(state.workers, ref)
    busy = max(state.busy - 1, 0)
    %{state | workers: workers, busy: busy}
  end

  defp pump(%{busy: busy, max: max} = state) when busy >= max, do: state

  defp pump(state) do
    case :queue.out(state.queue) do
      {:empty, _} ->
        state

      {{:value, item_id}, queue} ->
        task =
          Task.Supervisor.async_nolink(Hivefin.Metadata.TaskSupervisor, fn ->
            Worker.refresh_item(item_id)
          end)

        state = %{
          state
          | queue: queue,
            busy: state.busy + 1,
            workers: Map.put(state.workers, task.ref, item_id)
        }

        pump(state)
    end
  end
end
