defmodule Hivefin.Playback.Hls.PlaylistTest do
  use ExUnit.Case, async: true

  alias Hivefin.Playback.Hls.Playlist

  describe "build_vod/4" do
    test "is VOD, not EVENT, and terminates with ENDLIST" do
      playlist = Playlist.build_vod(30.0, 4, "sess-1", "tok")

      assert playlist =~ "#EXT-X-PLAYLIST-TYPE:VOD"
      assert playlist =~ "#EXT-X-ENDLIST"
      refute playlist =~ "EVENT"
    end

    test "segment count is ceil(runtime/segment) and EXTINF durations sum to the runtime" do
      runtime = 30.0
      segment = 4

      playlist = Playlist.build_vod(runtime, segment, "sess-2", "tok")

      extinf_values =
        Regex.scan(~r/^#EXTINF:([\d.]+),$/m, playlist)
        |> Enum.map(fn [_, v] -> String.to_float(v) end)

      # Non-vacuous: fails if the regex matched nothing.
      assert extinf_values != []
      assert length(extinf_values) == ceil(runtime / segment)
      assert_in_delta Enum.sum(extinf_values), runtime, 0.001
    end

    test "final EXTINF is the remainder, omitted when the runtime divides evenly" do
      # 8s runtime / 4s segments == exactly 2 full segments, no remainder line.
      playlist = Playlist.build_vod(8.0, 4, "sess-3", "tok")

      extinf_values =
        Regex.scan(~r/^#EXTINF:([\d.]+),$/m, playlist)
        |> Enum.map(fn [_, v] -> String.to_float(v) end)

      assert extinf_values != []
      assert length(extinf_values) == 2
      assert Enum.all?(extinf_values, &(&1 == 4.0))
    end

    test "segment URIs keep the hls/<session_id>/seg_NNN.ts?api_key=<token> shape" do
      playlist = Playlist.build_vod(9.0, 4, "abc-123", "test-token-123")

      uris =
        playlist
        |> String.split("\n")
        |> Enum.filter(&String.starts_with?(&1, "hls/"))

      # Non-vacuous: fails if no segment URIs were emitted.
      assert uris != []
      assert "hls/abc-123/seg_000.ts?api_key=test-token-123" in uris
      assert "hls/abc-123/seg_001.ts?api_key=test-token-123" in uris
      assert "hls/abc-123/seg_002.ts?api_key=test-token-123" in uris
      assert length(uris) == 3
    end

    test "token is percent-encoded for the query string" do
      playlist = Playlist.build_vod(4.0, 4, "sess-5", "a b&c")

      assert playlist =~ "api_key=a+b%26c"
    end
  end

  describe "build/4" do
    test "unknown or zero runtime falls back instead of emitting a malformed VOD playlist" do
      assert Playlist.build(nil, 4, "sess-6", "tok") == :fallback
      assert Playlist.build(0, 4, "sess-6", "tok") == :fallback
      assert Playlist.build(-5, 4, "sess-6", "tok") == :fallback
    end

    test "known runtime builds the VOD playlist" do
      assert {:ok, playlist} = Playlist.build(30.0, 4, "sess-7", "tok")
      assert playlist =~ "#EXT-X-PLAYLIST-TYPE:VOD"
    end
  end

  describe "response completeness" do
    test "playlist is a single, non-empty response with a non-empty segment list" do
      playlist = Playlist.build_vod(30.0, 4, "sess-8", "tok")

      refute playlist == ""

      segment_lines =
        playlist
        |> String.split("\n")
        |> Enum.filter(&String.starts_with?(&1, "hls/"))

      assert segment_lines != []
      assert Enum.all?(segment_lines, &String.contains?(&1, "seg_"))
    end
  end
end
