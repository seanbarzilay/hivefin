defmodule Hivefin.Sessions do
  @moduledoc """
  Live client sessions: which clients currently hold a WebSocket, what they can
  be commanded to do, and what they are playing.

  A session id is the client's access-token id, so socket-addressed commands and
  `GET /Sessions` agree without a second identifier scheme.

  Keys are duplicate on purpose: a client that reconnects before its previous
  socket process has terminated must not crash on register.
  """

  alias Hivefin.Accounts

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
    case Enum.filter(Registry.lookup(@registry, session_id), &(elem(&1, 0) == self())) do
      [] ->
        :ok

      [{_pid, current} | _] ->
        # ponytail: non-atomic replace — ~300ns window where a concurrent reader sees no
        # entry for this session. Measured p50 292ns / p99 2.4us with no yield point, and
        # update/2 fires ~1/10s per playing session, so exposure is ~3e-7. Revisit (separate
        # ETS table for mutable state) only if update/2 ever becomes hot.
        Registry.unregister(@registry, session_id)
        {:ok, _} = Registry.register(@registry, session_id, Map.merge(current, attrs))
        :ok
    end
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

  @doc "Registered attrs for `session_id`'s socket(s) — e.g. to check ownership before commanding it."
  def attrs(session_id) when is_binary(session_id) do
    @registry |> Registry.lookup(session_id) |> Enum.map(fn {_pid, attrs} -> attrs end)
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

  @doc """
  Access tokens for `user_id` that currently hold a live socket, each paired
  with its play state (`t:Dto.Session.from_access_token/2`'s `:state` opt).

  Single source of truth for "what is a session" — both `GET /Sessions` and
  the Sessions websocket push build their payload from this, so they can't
  drift. Without it, every access token ever issued (mostly dead rows from
  past logins) gets reported as a session; on the live server that was 147
  "sessions" for 1 real playback.

  `opts[:device_id]` filters like `Accounts.list_access_tokens/1` does.

  Registry keys are duplicate on purpose (a reconnecting client may briefly
  hold two sockets for the same session_id) — collapsed here so a session
  appears at most once.
  """
  def live_for_user(user_id, opts \\ []) do
    device_id = Keyword.get(opts, :device_id)

    live_by_session_id =
      list()
      |> Enum.uniq_by(& &1.session_id)
      |> Map.new(&{&1.session_id, &1})

    [user_id: user_id, device_id: device_id]
    |> Accounts.list_access_tokens()
    |> Enum.filter(&Map.has_key?(live_by_session_id, &1.id))
    |> Enum.map(&{&1, play_state(live_by_session_id[&1.id])})
  end

  defp play_state(entry) do
    %{
      item_id: Map.get(entry, :item_id),
      position_ticks: Map.get(entry, :position_ticks),
      is_paused: Map.get(entry, :is_paused, false)
    }
  end
end
