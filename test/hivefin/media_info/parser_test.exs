defmodule Hivefin.MediaInfo.ParserTest do
  use ExUnit.Case, async: true

  alias Hivefin.MediaInfo.Parser

  @fixture Path.expand("test/support/fixtures/ffprobe/sample_probe.json", File.cwd!())

  test "extracts video and audio stream metadata from ffprobe JSON" do
    json = File.read!(@fixture)
    assert {:ok, %{format: format, streams: streams}} = Parser.parse(json)

    assert format.duration == 1.0
    assert format.bit_rate == 116_264
    assert format.format_name =~ "mp4"

    video = Enum.find(streams, &(&1.type == :video))
    audio = Enum.find(streams, &(&1.type == :audio))
    subtitle = Enum.find(streams, &(&1.type == :subtitle))

    assert video.codec == "h264"
    assert video.width == 320
    assert video.height == 240
    assert video.is_default

    assert audio.codec == "aac"
    assert audio.channels == 2
    assert audio.language == "eng"
    assert audio.title == "English"

    assert subtitle.codec == "subrip"
    assert subtitle.language == "spa"
    assert subtitle.is_forced
  end

  test "returns error on invalid JSON" do
    assert {:error, _} = Parser.parse("not-json")
  end
end
