defmodule Hivefin.Playback.Hls.Playlist do
  @moduledoc """
  Pure builder for the VOD HLS playlist served for finite-runtime media.

  Upstream Jellyfin serves a VOD playlist (full segment list computed from
  the known runtime, plus `#EXT-X-ENDLIST`) for finite media, so hls.js
  treats it as a movie with a known duration and plays sequentially. We used
  to hand back ffmpeg's own `EVENT` playlist, which hls.js treats as a
  **live** stream and syncs to the live edge — our transcoder runs ~2.8x
  realtime, so the edge raced ahead of playback and hls.js skipped segments,
  leaving gaps that killed the MediaSource buffer
  (`DEMUXER_ERROR_COULD_NOT_PARSE`).

  Kept pure (runtime + segment duration + ids in, playlist string out) so it
  is unit-testable without spinning up ffmpeg.
  """

  # Jellyfin's tick unit (100ns). Runtime/segment math is done here, in
  # integers, instead of in float seconds, so binary floating point can't
  # drift segment boundaries relative to what the DB/ffmpeg agree on.
  @ticks_per_second 10_000_000

  @doc """
  Builds the VOD playlist for a source of known runtime, or returns
  `:fallback` when the runtime is unknown/zero — the caller should then
  serve ffmpeg's own EVENT playlist instead of emitting a VOD playlist with
  no segments.
  """
  @spec build(number() | nil, number(), String.t(), String.t()) ::
          {:ok, String.t()} | :fallback
  def build(runtime_seconds, _segment_seconds, _session_id, _token)
      when not is_number(runtime_seconds) or runtime_seconds <= 0 do
    :fallback
  end

  def build(runtime_seconds, segment_seconds, session_id, token) do
    {:ok, build_vod(runtime_seconds, segment_seconds, session_id, token)}
  end

  @doc """
  Builds a `#EXT-X-PLAYLIST-TYPE:VOD` playlist.

  Segment count is `ceil(runtime_seconds / segment_seconds)`; the final
  `#EXTINF` carries the remainder (omitted when the runtime divides evenly),
  so the sum of all `#EXTINF` durations equals the runtime exactly — a
  mismatch here silently desyncs seeking on the client.

  `segment_seconds` must be the same value passed to ffmpeg's `-hls_time`
  (see `Hivefin.Playback.FFmpeg.Args.hls_segment_seconds/0`).
  """
  @spec build_vod(number(), number(), String.t(), String.t()) :: String.t()
  def build_vod(runtime_seconds, segment_seconds, session_id, token)
      when is_number(runtime_seconds) and runtime_seconds > 0 and
             is_number(segment_seconds) and segment_seconds > 0 do
    durations = segment_durations(runtime_seconds, segment_seconds)
    token_q = URI.encode_www_form(token)
    hls_prefix = "hls/#{session_id}"

    header = [
      "#EXTM3U",
      "#EXT-X-VERSION:6",
      "#EXT-X-TARGETDURATION:#{ceil(segment_seconds)}",
      "#EXT-X-MEDIA-SEQUENCE:0",
      "#EXT-X-PLAYLIST-TYPE:VOD",
      "#EXT-X-INDEPENDENT-SEGMENTS"
    ]

    segment_lines =
      durations
      |> Enum.with_index()
      |> Enum.flat_map(fn {duration, index} ->
        name = "seg_#{pad3(index)}.ts"
        ["#EXTINF:#{format_duration(duration)},", "#{hls_prefix}/#{name}?api_key=#{token_q}"]
      end)

    Enum.join(header ++ segment_lines ++ ["#EXT-X-ENDLIST"], "\n") <> "\n"
  end

  defp segment_durations(runtime_seconds, segment_seconds) do
    runtime_ticks = round(runtime_seconds * @ticks_per_second)
    segment_ticks = round(segment_seconds * @ticks_per_second)

    full_segments = div(runtime_ticks, segment_ticks)
    remainder_ticks = rem(runtime_ticks, segment_ticks)

    full = List.duplicate(segment_seconds * 1.0, full_segments)

    if remainder_ticks > 0 do
      full ++ [remainder_ticks / @ticks_per_second]
    else
      full
    end
  end

  defp pad3(index), do: index |> Integer.to_string() |> String.pad_leading(3, "0")

  defp format_duration(seconds), do: :erlang.float_to_binary(seconds * 1.0, decimals: 6)
end
