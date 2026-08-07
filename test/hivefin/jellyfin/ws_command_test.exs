defmodule Hivefin.Jellyfin.WsCommandTest do
  use ExUnit.Case, async: true

  alias Hivefin.Jellyfin.WsCommand

  @user "11111111-1111-1111-1111-111111111111"

  test "play/2 carries the required PlayRequest fields" do
    msg = WsCommand.play(@user, %{"ItemIds" => ["abc"], "PlayCommand" => "PlayNow"})

    assert msg["MessageType"] == "Play"
    assert msg["MessageId"]
    data = msg["Data"]
    assert data["PlayCommand"] == "PlayNow"
    assert data["ControllingUserId"] == @user
    assert data["ItemIds"] == ["abc"]
  end

  test "play/2 defaults PlayCommand to PlayNow rather than omitting it" do
    data = WsCommand.play(@user, %{"ItemIds" => ["abc"]})["Data"]

    assert data["PlayCommand"] == "PlayNow"
  end

  test "play/2 rejects an unknown PlayCommand" do
    assert {:error, :invalid_command} =
             WsCommand.play(@user, %{"PlayCommand" => "Teleport"})
  end

  test "playstate/2 carries the required Command field" do
    msg = WsCommand.playstate("Seek", %{"SeekPositionTicks" => 100})

    assert msg["MessageType"] == "Playstate"
    assert msg["Data"]["Command"] == "Seek"
    assert msg["Data"]["SeekPositionTicks"] == 100
  end

  test "playstate/2 rejects an unknown command" do
    assert {:error, :invalid_command} = WsCommand.playstate("Explode", %{})
  end

  test "general/3 always sends Arguments as an object" do
    msg = WsCommand.general("SetVolume", @user, %{})

    assert msg["MessageType"] == "GeneralCommand"
    data = msg["Data"]
    assert data["Name"] == "SetVolume"
    assert data["ControllingUserId"] == @user
    # Required and non-null: an absent Arguments discards the message.
    assert data["Arguments"] == %{}
    refute is_nil(data["Arguments"])
  end

  test "general/3 stringifies argument values" do
    data = WsCommand.general("SetVolume", @user, %{"Volume" => 50})["Data"]

    assert data["Arguments"] == %{"Volume" => "50"}
  end
end
