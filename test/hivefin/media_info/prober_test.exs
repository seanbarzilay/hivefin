defmodule Hivefin.MediaInfo.ProberTest do
  use ExUnit.Case, async: true

  alias Hivefin.MediaInfo.Prober

  @movie Path.expand(
           "test/support/fixtures/media_tree/movies/Big Buck Bunny (2008)/Big Buck Bunny (2008).mp4",
           File.cwd!()
         )

  @tag :ffprobe
  test "probes fixture mp4 for video and audio streams" do
    assert {:ok, %{format: format, streams: streams}} = Prober.probe(@movie)
    assert is_float(format.duration) or is_nil(format.duration)

    types = Enum.map(streams, & &1.type)
    assert :video in types
    assert :audio in types

    video = Enum.find(streams, &(&1.type == :video))
    assert video.width == 320
    assert video.height == 240
    assert video.codec in ["h264", "mpeg4"]
  end

  test "returns error for missing file" do
    assert {:error, :enoent} = Prober.probe("/tmp/hivefin-missing-#{System.unique_integer()}.mp4")
  end
end
