defmodule Hivefin.SessionsTest do
  use ExUnit.Case, async: false

  alias Hivefin.Sessions

  setup do
    # Registry entries are owned by the registering process, so each test
    # registers from a short-lived task to avoid leaking into the next.
    :ok
  end

  defp spawn_session(session_id, attrs \\ %{}) do
    test = self()

    pid =
      spawn(fn ->
        Sessions.register(session_id, attrs)
        send(test, :registered)

        receive do
          {:jellyfin_push, msg} ->
            send(test, {:got_push, msg})
            Process.sleep(:infinity)

          :stop ->
            :ok
        end
      end)

    assert_receive :registered
    pid
  end

  test "register/2 then list/0 includes the session" do
    id = Ecto.UUID.generate()
    pid = spawn_session(id, %{user_id: "u1", client: "Jellyfin Web"})

    sessions = Sessions.list()
    entry = Enum.find(sessions, &(&1.session_id == id))

    assert entry.user_id == "u1"
    assert entry.client == "Jellyfin Web"
    assert entry.pid == pid

    send(pid, :stop)
  end

  test "pids/1 returns the socket processes for a session" do
    id = Ecto.UUID.generate()
    pid = spawn_session(id)

    assert Sessions.pids(id) == [pid]

    send(pid, :stop)
  end

  test "push/2 delivers to the session's socket" do
    id = Ecto.UUID.generate()
    pid = spawn_session(id)

    assert :ok = Sessions.push(id, %{"MessageType" => "Play"})
    assert_receive {:got_push, %{"MessageType" => "Play"}}

    send(pid, :stop)
  end

  test "push/2 to an unknown session reports no_session" do
    assert {:error, :no_session} = Sessions.push(Ecto.UUID.generate(), %{})
  end

  test "entries disappear when the owning process dies" do
    id = Ecto.UUID.generate()
    pid = spawn_session(id)

    ref = Process.monitor(pid)
    send(pid, :stop)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}

    # Registry cleanup is asynchronous with respect to process death.
    Process.sleep(50)
    assert Sessions.pids(id) == []
  end

  test "two sockets may share a session id without crashing" do
    id = Ecto.UUID.generate()
    a = spawn_session(id)
    b = spawn_session(id)

    assert length(Sessions.pids(id)) == 2

    send(a, :stop)
    send(b, :stop)
  end

  test "subscribe/0 receives broadcast_changed/0" do
    Sessions.subscribe()
    Sessions.broadcast_changed()

    assert_receive :sessions_changed
  end

  test "update/2 merges into the calling process's own entry" do
    id = Ecto.UUID.generate()
    test = self()

    pid =
      spawn(fn ->
        Sessions.register(id, %{user_id: "u1"})
        Sessions.update(id, %{now_playing_item_id: "movie-1"})
        send(test, :updated)
        Process.sleep(:infinity)
      end)

    assert_receive :updated

    entry = Enum.find(Sessions.list(), &(&1.session_id == id))
    assert entry.now_playing_item_id == "movie-1"
    assert entry.user_id == "u1"

    Process.exit(pid, :kill)
  end

  test "put_state/2 asks the socket process to update, since Registry entries are caller-owned" do
    id = Ecto.UUID.generate()
    test = self()

    pid =
      spawn(fn ->
        Sessions.register(id, %{user_id: "u1"})
        send(test, :ready)

        receive do
          {:jellyfin_session_state, attrs} ->
            Sessions.update(id, attrs)
            send(test, :applied)
            Process.sleep(:infinity)
        end
      end)

    assert_receive :ready
    assert :ok = Sessions.put_state(id, %{position_ticks: 42})
    assert_receive :applied

    entry = Enum.find(Sessions.list(), &(&1.session_id == id))
    assert entry.position_ticks == 42

    Process.exit(pid, :kill)
  end

  test "put_state/2 on an unknown session reports no_session" do
    assert {:error, :no_session} = Sessions.put_state(Ecto.UUID.generate(), %{})
  end

  test "update/2 from a process with no registration does not create an entry" do
    id = Ecto.UUID.generate()
    test = self()

    spawn(fn ->
      Sessions.update(id, %{position_ticks: 1})
      send(test, :done)
      Process.sleep(:infinity)
    end)

    assert_receive :done
    assert Sessions.pids(id) == []
    assert {:error, :no_session} = Sessions.push(id, %{})
  end
end
