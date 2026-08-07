defmodule HivefinWeb.JellyfinSocketTest do
  use ExUnit.Case, async: true

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
end
