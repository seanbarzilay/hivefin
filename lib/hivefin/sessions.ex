defmodule Hivefin.Sessions do
  @moduledoc """
  Live client sessions: which clients currently hold a WebSocket, what they can
  be commanded to do, and what they are playing.

  A session id is the client's access-token id, so socket-addressed commands and
  `GET /Sessions` agree without a second identifier scheme.

  Keys are duplicate on purpose: a client that reconnects before its previous
  socket process has terminated must not crash on register.
  """

  @registry Hivefin.Sessions.Registry
  @topic "jellyfin:sessions"

  @doc "Child spec for the application supervision tree."
  def child_spec(_opts) do
    Registry.child_spec(keys: :duplicate, name: @registry)
  end

  @doc "Registers the calling process as a socket for `session_id`."
  def register(session_id, attrs \\ %{}) when is_binary(session_id) do
    {:ok, _} = Registry.register(@registry, session_id, attrs)
    :ok
  end

  @doc """
  Merges `attrs` into **the calling process's own** entry.

  `Registry.update_value/3` only supports `:unique` registries (it raises for
  `:duplicate` ones, which this registry is on purpose), so the caller's entry
  is instead replaced via unregister+register — an operation only the owning
  process can perform for itself. This is callable only from the socket
  process itself. Request processes must use `put_state/2`.
  """
  def update(session_id, attrs) when is_binary(session_id) and is_map(attrs) do
    current =
      @registry
      |> Registry.lookup(session_id)
      |> Enum.find_value(%{}, fn {pid, value} -> pid == self() && value end)

    Registry.unregister(@registry, session_id)
    {:ok, _} = Registry.register(@registry, session_id, Map.merge(current, attrs))
    :ok
  end

  @doc """
  Asks the socket process(es) for `session_id` to merge `attrs` into their entry.

  Used by controllers: a request process owns no registration, so calling
  `update/2` there would silently do nothing.
  """
  def put_state(session_id, attrs) when is_binary(session_id) and is_map(attrs) do
    case pids(session_id) do
      [] ->
        {:error, :no_session}

      pids ->
        Enum.each(pids, &send(&1, {:jellyfin_session_state, attrs}))
        :ok
    end
  end

  @doc "All live sessions, each with `:session_id` and `:pid`."
  def list do
    Registry.select(@registry, [{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}])
    |> Enum.map(fn {session_id, pid, attrs} ->
      attrs |> Map.put(:session_id, session_id) |> Map.put(:pid, pid)
    end)
  end

  @doc "Socket processes for `session_id`."
  def pids(session_id) when is_binary(session_id) do
    @registry |> Registry.lookup(session_id) |> Enum.map(fn {pid, _attrs} -> pid end)
  end

  @doc "Sends `message` to every socket for `session_id`."
  def push(session_id, message) when is_binary(session_id) do
    case pids(session_id) do
      [] ->
        {:error, :no_session}

      pids ->
        Enum.each(pids, &send(&1, {:jellyfin_push, message}))
        :ok
    end
  end

  @doc "Subscribes the caller to session change notifications."
  def subscribe, do: Phoenix.PubSub.subscribe(Hivefin.PubSub, @topic)

  @doc "Notifies subscribers that the session list or its state changed."
  def broadcast_changed, do: Phoenix.PubSub.broadcast(Hivefin.PubSub, @topic, :sessions_changed)
end
