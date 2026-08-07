defmodule Hivefin.Jellyfin.AuthTest do
  use ExUnit.Case, async: true
  alias Hivefin.Jellyfin.Auth

  test "parses MediaBrowser authorization header" do
    header =
      ~s(MediaBrowser Client="Jellyfin Web", Device="Firefox", DeviceId="abc", Version="10.9.0", Token="tok123")

    assert {:ok, parsed} = Auth.parse_authorization(header)
    assert parsed.client == "Jellyfin Web"
    assert parsed.device == "Firefox"
    assert parsed.device_id == "abc"
    assert parsed.version == "10.9.0"
    assert parsed.token == "tok123"
  end

  test "returns invalid for nil or non-MediaBrowser headers" do
    assert {:error, :invalid} = Auth.parse_authorization(nil)
    assert {:error, :invalid} = Auth.parse_authorization("Bearer abc")
  end

  test "empty Token becomes nil" do
    header = ~s(MediaBrowser Client="C", Device="D", DeviceId="id", Version="1", Token="")
    assert {:ok, parsed} = Auth.parse_authorization(header)
    assert parsed.token == nil
  end

  test "decodes encodeURIComponent field values from SDK" do
    header =
      "MediaBrowser Client=\"Jellyfin%20Web%20(Vue)\", Device=\"Chrome\", DeviceId=\"abc\", Version=\"0.0.0\", Token=\"tok\""

    assert {:ok, parsed} = Auth.parse_authorization(header)
    assert parsed.client == "Jellyfin Web " <> "(Vue)"
  end
end



