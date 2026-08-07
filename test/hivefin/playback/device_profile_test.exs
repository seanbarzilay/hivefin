defmodule Hivefin.Playback.DeviceProfileTest do
  use ExUnit.Case, async: true

  alias Hivefin.Playback.DeviceProfile

  test "from_playback_info_body reads top-level DeviceProfile" do
    body = %{
      "DeviceProfile" => %{
        "DirectPlayProfiles" => [
          %{"Container" => "mp4", "Type" => "Video", "VideoCodec" => "h264", "AudioCodec" => "aac"}
        ]
      }
    }

    profile = DeviceProfile.from_playback_info_body(body)
    assert profile.direct_play_containers == ["mp4"]
    assert "h264" in profile.video_codecs
    refute "mkv" in profile.direct_play_containers
  end

  test "from_playback_info_body reads nested playbackInfoDto.DeviceProfile (SDK shape)" do
    body = %{
      "playbackInfoDto" => %{
        "DeviceProfile" => %{
          "DirectPlayProfiles" => [
            %{"Container" => "mp4", "Type" => "Video", "VideoCodec" => "h264", "AudioCodec" => "aac"}
          ]
        }
      }
    }

    profile = DeviceProfile.from_playback_info_body(body)
    assert profile.direct_play_containers == ["mp4"]
    assert "h264" in profile.video_codecs
    # Must NOT fall back to permissive default (which includes mkv)
    refute "mkv" in profile.direct_play_containers
  end

  test "default profile still allows mkv DirectPlay" do
    assert "mkv" in DeviceProfile.default().direct_play_containers
  end
end
