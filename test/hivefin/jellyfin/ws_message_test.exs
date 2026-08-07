defmodule Hivefin.Jellyfin.WsMessageTest do
  use ExUnit.Case, async: true

  alias Hivefin.Jellyfin.WsMessage

  test "build/2 always carries MessageType and a UUID MessageId" do
    msg = WsMessage.build("Sessions", [])

    assert msg["MessageType"] == "Sessions"
    assert {:ok, _} = Ecto.UUID.cast(msg["MessageId"])
    assert msg["Data"] == []
  end

  test "build/2 gives each message a distinct MessageId" do
    a = WsMessage.build("KeepAlive", nil)
    b = WsMessage.build("KeepAlive", nil)

    refute a["MessageId"] == b["MessageId"]
  end

  test "build/2 omits Data when nil rather than sending null" do
    msg = WsMessage.build("KeepAlive", nil)

    refute Map.has_key?(msg, "Data")
  end

  test "force_keep_alive/1 encodes the required Int Data and MessageId" do
    decoded = WsMessage.force_keep_alive(60) |> Jason.decode!()

    assert decoded["MessageType"] == "ForceKeepAlive"
    # Data is a non-null Int in the SDK — a missing or null value is discarded.
    assert decoded["Data"] == 60
    assert is_integer(decoded["Data"])
    assert {:ok, _} = Ecto.UUID.cast(decoded["MessageId"])
  end

  test "keep_alive/0 encodes a MessageId" do
    decoded = WsMessage.keep_alive() |> Jason.decode!()

    assert decoded["MessageType"] == "KeepAlive"
    assert {:ok, _} = Ecto.UUID.cast(decoded["MessageId"])
  end
end
