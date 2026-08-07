defmodule HivefinWeb.JellyfinSocketTest do
  use Hivefin.DataCase, async: false

  alias HivefinWeb.JellyfinSocket

  defp state do
    %{
      user_id: Ecto.UUID.generate(),
      session_id: Ecto.UUID.generate(),
      device_id: "pixel",
      subscriptions: MapSet.new()
    }
  end

  defp frame(map), do: {Jason.encode!(map), [opcode: :text]}

  defp persisted_state do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Hivefin.Accounts.create_user(%{
        name: "Sock",
        username: "sockuser#{n}",
        password: "password1",
        admin: true
      })

    {:ok, _token, at} =
      Hivefin.Accounts.issue_token(user, %{
        device_id: "dev-#{n}",
        device_name: "Dev",
        client: "Jellyfin Web",
        client_version: "10.9.0"
      })

    %{
      user_id: user.id,
      session_id: at.id,
      device_id: "dev-#{n}",
      subscriptions: MapSet.new()
    }
  end

  test "init pushes ForceKeepAlive so the client starts its keepalive timer" do
    assert {:push, {:text, json}, _state} = JellyfinSocket.init(state())

    decoded = Jason.decode!(json)
    assert decoded["MessageType"] == "ForceKeepAlive"
    assert is_integer(decoded["Data"])
    assert decoded["MessageId"]
  end

  test "KeepAlive is echoed" do
    assert {:push, {:text, json}, _state} =
             JellyfinSocket.handle_in(frame(%{"MessageType" => "KeepAlive"}), state())

    assert Jason.decode!(json)["MessageType"] == "KeepAlive"
  end

  test "unknown MessageType is ignored without closing the socket" do
    s = state()

    assert {:ok, ^s} =
             JellyfinSocket.handle_in(frame(%{"MessageType" => "TotallyMadeUp"}), s)
  end

  test "malformed JSON is ignored without closing the socket" do
    s = state()

    assert {:ok, ^s} = JellyfinSocket.handle_in({"{not json", [opcode: :text]}, s)
  end

  test "a message with no MessageType is ignored" do
    s = state()

    assert {:ok, ^s} = JellyfinSocket.handle_in(frame(%{"Data" => "x"}), s)
  end

  test "binary frames are ignored" do
    s = state()

    assert {:ok, ^s} = JellyfinSocket.handle_in({<<0, 1, 2>>, [opcode: :binary]}, s)
  end

  test "no-op subscription messages are accepted" do
    for type <- [
          "ActivityLogEntryStart",
          "ActivityLogEntryStop",
          "ScheduledTasksInfoStart",
          "ScheduledTasksInfoStop"
        ] do
      s = state()
      assert {:ok, ^s} = JellyfinSocket.handle_in(frame(%{"MessageType" => type}), s)
    end
  end

  test "an arbitrary handle_info message does not crash the socket" do
    s = state()
    assert {:ok, ^s} = JellyfinSocket.handle_info(:some_unexpected_message, s)
  end

  test "terminate returns :ok" do
    assert :ok = JellyfinSocket.terminate(:remote, state())
  end

  describe "session registration and Sessions push" do
    test "init registers the socket so it appears in Sessions.list/0" do
      s = state()

      assert {:push, _frame, _state} = JellyfinSocket.init(s)

      assert Enum.any?(Hivefin.Sessions.list(), &(&1.session_id == s.session_id))
    end

    test "SessionsStart pushes a Sessions message and records the subscription" do
      s = persisted_state()
      {:push, _, s} = JellyfinSocket.init(s)

      assert {:push, {:text, json}, new_state} =
               JellyfinSocket.handle_in(
                 frame(%{"MessageType" => "SessionsStart", "Data" => "0,1500"}),
                 s
               )

      decoded = Jason.decode!(json)
      assert decoded["MessageType"] == "Sessions"
      assert is_list(decoded["Data"])
      assert decoded["Data"] != []
      assert MapSet.member?(new_state.subscriptions, "Sessions")
    end

    test "SessionsStop clears the subscription" do
      s = state()
      {:push, _, s} = JellyfinSocket.init(s)
      {:push, _, s} = JellyfinSocket.handle_in(frame(%{"MessageType" => "SessionsStart"}), s)

      assert {:ok, new_state} =
               JellyfinSocket.handle_in(frame(%{"MessageType" => "SessionsStop"}), s)

      refute MapSet.member?(new_state.subscriptions, "Sessions")
    end

    test "a jellyfin_push message is forwarded to the client verbatim" do
      s = state()

      assert {:push, {:text, json}, ^s} =
               JellyfinSocket.handle_info(
                 {:jellyfin_push, %{"MessageType" => "Play", "MessageId" => "x"}},
                 s
               )

      assert Jason.decode!(json)["MessageType"] == "Play"
    end

    test "sessions_changed pushes Sessions only when subscribed" do
      s = state()

      # Not subscribed: no push.
      assert {:ok, ^s} = JellyfinSocket.handle_info(:sessions_changed, s)

      subscribed = %{s | subscriptions: MapSet.new(["Sessions"])}

      assert {:push, {:text, json}, _} =
               JellyfinSocket.handle_info(:sessions_changed, subscribed)

      assert Jason.decode!(json)["MessageType"] == "Sessions"
    end

    test "every session in a Sessions push carries the required fields" do
      s = persisted_state()
      {:push, _, s} = JellyfinSocket.init(s)

      {:push, {:text, json}, _} =
        JellyfinSocket.handle_in(frame(%{"MessageType" => "SessionsStart"}), s)

      sessions = Jason.decode!(json)["Data"]
      # Without this the for-loop below can pass vacuously on an empty list.
      assert sessions != [], "expected at least one session in the Sessions push"

      for session <- sessions, key <- Hivefin.Jellyfin.Dto.Session.required_keys() do
        assert Map.has_key?(session, key), "SessionInfoDto missing #{key}"
        refute is_nil(session[key]), "SessionInfoDto #{key} is null"
      end
    end
  end
end
