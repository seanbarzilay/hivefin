defmodule Hivefin.Playback.DecisionTest do
  use ExUnit.Case, async: true

  alias Hivefin.Playback.Decision
  alias Hivefin.Playback.DeviceProfile

  test "h264 aac mp4 direct plays when profile allows" do
    source = %{container: "mp4", video_codec: "h264", audio_codec: "aac"}
    profile = %{direct_play_containers: ["mp4"], video_codecs: ["h264"], audio_codecs: ["aac"]}
    assert {:direct_play, meta} = Decision.choose(source, profile)
    assert meta.reason == :compatible
  end

  test "mkv h264 aac remuxes to fMP4 when mkv not direct-playable" do
    source = %{container: "mkv", video_codec: "h264", audio_codec: "aac"}
    profile = %{direct_play_containers: ["mp4"], video_codecs: ["h264"], audio_codecs: ["aac"]}
    assert {:direct_stream, meta} = Decision.choose(source, profile)
    assert meta.reason == :container_not_allowed
    assert meta.remux_container == "mp4"
  end

  test "mkv hevc remuxes to ts when mkv not direct-playable" do
    source = %{container: "mkv", video_codec: "hevc", audio_codec: "ac3"}
    profile = %{direct_play_containers: ["mp4"], video_codecs: ["hevc"], audio_codecs: ["ac3"]}
    assert {:direct_stream, meta} = Decision.choose(source, profile)
    assert meta.remux_container == "ts"
  end

  test "default profile DirectPlays mkv hevc ac3" do
    source = %{container: "mkv", video_codec: "hevc", audio_codec: "ac3"}
    assert {:direct_play, _} = Decision.choose(source, DeviceProfile.default())
  end

  test "unsupported video codec forces transcode" do
    source = %{container: "mp4", video_codec: "hevc", audio_codec: "aac"}
    profile = %{direct_play_containers: ["mp4"], video_codecs: ["h264"], audio_codecs: ["aac"]}
    assert {:transcode, meta} = Decision.choose(source, profile)
    assert meta.reason == :video_codec_not_allowed
  end

  test "unsupported audio codec forces transcode" do
    source = %{container: "mp4", video_codec: "h264", audio_codec: "dts"}
    profile = %{direct_play_containers: ["mp4"], video_codecs: ["h264"], audio_codecs: ["aac"]}
    assert {:transcode, meta} = Decision.choose(source, profile)
    assert meta.reason == :audio_codec_not_allowed
  end

  test "accepts MediaSource-shaped maps with media_streams" do
    source = %{
      container: "mp4",
      media_streams: [
        %{type: :video, codec: "h264"},
        %{type: :audio, codec: "aac"}
      ]
    }

    profile = DeviceProfile.default()
    assert {:direct_play, _} = Decision.choose(source, profile)
  end

  test "empty profile falls back to default-compatible direct play for mp4 h264 aac" do
    source = %{container: "mp4", video_codec: "h264", audio_codec: "aac"}
    assert {:direct_play, _} = Decision.choose(source, DeviceProfile.default())
  end

  test "codec comparison is case-insensitive" do
    source = %{container: "MP4", video_codec: "H264", audio_codec: "AAC"}
    profile = %{direct_play_containers: ["mp4"], video_codecs: ["h264"], audio_codecs: ["aac"]}
    assert {:direct_play, _} = Decision.choose(source, profile)
  end

  test "empty codec allow-lists mean any codec" do
    source = %{container: "mp4", video_codec: "hevc", audio_codec: "dts"}
    profile = %{direct_play_containers: ["mp4"], video_codecs: [], audio_codecs: []}
    assert {:direct_play, _} = Decision.choose(source, profile)
  end

  test "empty container allow-list means any container" do
    source = %{container: "mkv", video_codec: "h264", audio_codec: "aac"}
    profile = %{direct_play_containers: [], video_codecs: ["h264"], audio_codecs: ["aac"]}
    assert {:direct_play, _} = Decision.choose(source, profile)
  end

  test "DeviceProfile keeps empty codec lists as allow-all (does not substitute defaults)" do
    profile =
      DeviceProfile.from_jellyfin(%{
        "DirectPlayProfiles" => [
          %{"Container" => "mp4", "Type" => "Video"}
        ]
      })

    assert profile.direct_play_containers == ["mp4"]
    assert profile.video_codecs == []
    assert profile.audio_codecs == []

    source = %{container: "mp4", video_codec: "vp9", audio_codec: "opus"}
    assert {:direct_play, _} = Decision.choose(source, profile)
  end
end
