defmodule Hivefin.Playback.FFmpeg.Args do
  @moduledoc """
  Pure FFmpeg CLI argument builders for remux and transcode.

  Returns argument lists only (no binary path). Callers prepend the ffmpeg
  executable. **Never** accept raw client filter strings — only allowlisted
  keys from these builders.
  """

  @type encoder :: :libx264 | :videotoolbox | :nvenc | :vaapi

  @type remux_opts :: %{
          required(:output) => String.t(),
          optional(:format) => String.t(),
          optional(:hls_segment_pattern) => String.t(),
          optional(:hls_time) => pos_integer()
        }

  @type transcode_opts :: %{
          required(:output) => String.t(),
          required(:encoder) => encoder(),
          optional(:height) => pos_integer(),
          optional(:video_bitrate) => String.t(),
          optional(:audio_bitrate) => String.t(),
          optional(:format) => String.t(),
          optional(:hls_segment_pattern) => String.t(),
          optional(:hls_time) => pos_integer()
        }

  # Fragmented MP4 is progressive-pipe friendly and playable in HTML5 <video>
  # (Chrome/Firefox/Safari). Plain MPEG-TS is not.
  @fmp4_movflags "frag_keyframe+empty_moov+default_base_moof"

  # Single source of truth for HLS segment duration in seconds. The VOD
  # playlist we generate for clients (Hivefin.Playback.Hls.Playlist, served
  # by HivefinWeb.Jellyfin.VideoController) must agree with what we tell
  # ffmpeg here — a mismatch silently desyncs seeking.
  @hls_segment_seconds 4

  @doc """
  Segment duration (seconds) passed to ffmpeg's `-hls_time`. Shared with the
  VOD playlist builder so the durations advertised to clients always match
  what ffmpeg actually writes.
  """
  @spec hls_segment_seconds() :: pos_integer()
  def hls_segment_seconds, do: @hls_segment_seconds

  @doc """
  Builds args for container remux (stream copy, no re-encode).

  ## Options
  - `:output` — path, `"pipe:1"`, or HLS playlist path
  - `:format` — `"mp4"` (default fragmented progressive), `"mpegts"`, or `"hls"`
  - `:hls_segment_pattern` — required when format is `"hls"`
  - `:hls_time` — segment duration seconds (default: see `hls_segment_seconds/0`)
  """
  @spec remux(String.t(), remux_opts() | map()) :: [String.t()]
  def remux(input, opts) when is_binary(input) and is_map(opts) do
    output = Map.fetch!(opts, :output)
    format = Map.get(opts, :format, "mp4")

    [
      "-hide_banner",
      "-loglevel",
      "error",
      # Port has no TTY; avoid stdin control interference.
      "-nostdin",
      # Rebuild a clean timeline from 0 so HLS clients do not see source offsets
      # (many rips start at pts≈minutes).
      "-fflags",
      "+genpts",
      "-i",
      input,
      "-map",
      "0:v:0",
      "-map",
      "0:a:0?",
      "-c",
      "copy",
      # Drop data/attachment/subtitle streams that break TS/fMP4 remux.
      "-dn",
      "-sn",
      # Do NOT use -copyts: many rips start at pts≈minutes; browsers then show
      # 00:00 forever or abort progressive fMP4 (start_time != 0).
      "-start_at_zero",
      "-avoid_negative_ts",
      "make_zero",
      "-muxdelay",
      "0",
      "-muxpreload",
      "0"
    ] ++ container_args(format, output, opts)
  end

  @doc """
  Builds args for video/audio re-encode.

  ## Options
  - `:output` — path, `"pipe:1"`, or HLS playlist path
  - `:encoder` — `:libx264 | :videotoolbox | :nvenc | :vaapi`
  - `:height` — target height for scale filter (even width auto)
  - `:format` — `"mp4"` (default fragmented progressive), `"mpegts"`, or `"hls"`
  - `:hls_segment_pattern` — required when format is `"hls"`
  - `:hls_time` — segment duration seconds (default: see `hls_segment_seconds/0`)
  - `:video_bitrate` — used by HW encoders (default `"4M"`)
  - `:audio_bitrate` — AAC bitrate (default `"128k"`)
  """
  @spec transcode(String.t(), transcode_opts() | map()) :: [String.t()]
  def transcode(input, opts) when is_binary(input) and is_map(opts) do
    output = Map.fetch!(opts, :output)
    encoder = Map.fetch!(opts, :encoder)
    format = Map.get(opts, :format, "mp4")
    height = Map.get(opts, :height)
    video_bitrate = Map.get(opts, :video_bitrate, "4M")
    audio_bitrate = Map.get(opts, :audio_bitrate, "128k")

    base = [
      "-hide_banner",
      "-loglevel",
      "error",
      "-nostdin",
      "-fflags",
      "+genpts",
      "-i",
      input,
      # Drop container metadata / DOVI side-data that confuses browser MSE.
      "-map_metadata",
      "-1",
      "-map",
      "0:v:0",
      "-map",
      "0:a:0?",
      "-dn",
      "-sn"
    ]

    video = video_encode_args(encoder, video_bitrate)
    # VAAPI injects its own -vf chain; skip software scale on that path.
    # setpts/asetpts force a timeline from 0 — source files often start at
    # non-zero PTS which breaks hls.js after a few segments.
    filters = if encoder == :vaapi, do: [], else: video_filter_args(height)
    # Force IDR every @hls_segment_seconds so HLS segments start on
    # keyframes — this (not -g/-keyint_min below) is what actually pins
    # segment boundaries to wall-clock time, so it's the one GOP knob that
    # must track hls_segment_seconds/0.
    gop = ["-force_key_frames", "expr:gte(t,n_forced*#{@hls_segment_seconds})"]

    audio = [
      "-c:a",
      "aac",
      "-ac",
      "2",
      "-ar",
      "48000",
      "-b:a",
      audio_bitrate,
      # N/SR rebuilds a clean audio timeline (PTS-STARTPTS fails on some DV/HDR rips).
      "-af",
      "aresample=async=1:first_pts=0,asetpts=N/SR/TB"
    ]

    ts_fix = ["-avoid_negative_ts", "make_zero", "-muxdelay", "0", "-muxpreload", "0"]
    out = container_args(format, output, opts)

    base ++ video ++ gop ++ filters ++ audio ++ ts_fix ++ out
  end

  # Max GOP size (frames) as a safety net between forced keyframes above —
  # not the segment-boundary control itself, so it does NOT need to track
  # hls_segment_seconds/0. 96 assumes ~24fps; deriving an exact frame count
  # from a seconds value would need the source's real frame rate (23.976,
  # 25, 30, 60...), which isn't known here, so it stays a fixed frame count.
  # main + no B-frames: max HTML5 / Android WebView MSE compatibility.
  defp video_encode_args(:libx264, _bitrate) do
    [
      "-c:v",
      "libx264",
      "-preset",
      "veryfast",
      "-crf",
      "23",
      "-profile:v",
      "main",
      "-level",
      "4.0",
      "-bf",
      "0",
      "-g",
      "96",
      "-keyint_min",
      "96",
      "-sc_threshold",
      "0"
    ]
  end

  defp video_encode_args(:videotoolbox, bitrate) do
    ["-c:v", "h264_videotoolbox", "-b:v", bitrate, "-g", "96"]
  end

  defp video_encode_args(:nvenc, bitrate) do
    # fps_mode cfr is required on some NVENC builds so setpts/timeline resets stick.
    [
      "-c:v",
      "h264_nvenc",
      "-preset",
      "p4",
      "-b:v",
      bitrate,
      "-g",
      "96",
      "-forced-idr",
      "1",
      "-fps_mode",
      "cfr"
    ]
  end

  defp video_encode_args(:vaapi, bitrate) do
    # Device selection is environment-dependent; keep args allowlisted/static.
    [
      "-vaapi_device",
      "/dev/dri/renderD128",
      "-vf",
      "setpts=N/(FRAME_RATE*TB),format=nv12,hwupload",
      "-c:v",
      "h264_vaapi",
      "-b:v",
      bitrate
    ]
  end

  # Always convert to 8-bit BT.709 SDR for browser MSE:
  # - scale first (cheap) then HDR→SDR tonemap — PQ/HDR10/DV base layers look
  #   wrong (crushed/black) if only `format=yuv420p` is applied
  # - N-based setpts rebuilds timeline from 0 (PTS-STARTPTS fails on some DV rips)
  # - BT.709 tags so browsers do not treat output as HDR
  @sdr_tags ["-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "bt709"]

  # zscale linear → tonemap hable → BT.709 (requires ffmpeg built with libzimg).
  @hdr_tonemap "zscale=t=linear:npl=100,format=gbrpf32le,zscale=p=bt709,tonemap=tonemap=hable:desat=0,zscale=t=bt709:m=bt709:r=tv,format=yuv420p"

  # Fallback when zscale is unavailable (some desktop ffmpeg builds / CI).
  @sdr_only "format=yuv420p"

  defp video_filter_args(nil),
    do: ["-vf", "#{pixel_chain()},setpts=N/(FRAME_RATE*TB)"] ++ @sdr_tags

  defp video_filter_args(height) when is_integer(height) and height > 0,
    do:
      [
        "-vf",
        "scale=-2:#{height}:flags=fast_bilinear,#{pixel_chain()},setpts=N/(FRAME_RATE*TB)"
      ] ++ @sdr_tags

  defp video_filter_args(_),
    do: ["-vf", "#{pixel_chain()},setpts=N/(FRAME_RATE*TB)"] ++ @sdr_tags

  defp pixel_chain do
    if zscale_available?(), do: @hdr_tonemap, else: @sdr_only
  end

  # Cached probe — Args stays free of per-call process spawns after first hit.
  defp zscale_available? do
    case Application.get_env(:hivefin, :ffmpeg_has_zscale) do
      true -> true
      false -> false
      _ -> probe_zscale()
    end
  end

  defp probe_zscale do
    ffmpeg =
      Application.get_env(:hivefin, :ffmpeg_path) ||
        System.find_executable("ffmpeg") ||
        "ffmpeg"

    has? =
      case System.cmd(ffmpeg, ["-hide_banner", "-filters"], stderr_to_stdout: true) do
        {out, 0} -> String.contains?(out, "zscale")
        _ -> false
      end

    Application.put_env(:hivefin, :ffmpeg_has_zscale, has?)
    has?
  rescue
    _ ->
      Application.put_env(:hivefin, :ffmpeg_has_zscale, false)
      false
  end

  defp container_args("hls", output, opts) do
    segment_pattern = Map.fetch!(opts, :hls_segment_pattern)
    hls_time = Map.get(opts, :hls_time, @hls_segment_seconds)
    # Default mpegts: Android ExoPlayer DeviceProfile TranscodingProfile is
    # container=ts, protocol=hls. fMP4 is optional for browser MSE.
    segment_type = Map.get(opts, :hls_segment_type, "mpegts")
    init_filename = Map.get(opts, :hls_fmp4_init_filename, "init.mp4")

    fmp4_init =
      if segment_type == "fmp4" do
        ["-hls_fmp4_init_filename", init_filename]
      else
        []
      end

    [
      "-f",
      "hls",
      "-hls_time",
      Integer.to_string(hls_time),
      "-hls_list_size",
      "0",
      # EVENT (not VOD): stock FFmpeg only writes the .m3u8 after the encode
      # finishes when type=vod, so the client never sees segments mid-stream.
      # EVENT updates the playlist as each segment is finalized. We never
      # serve *this* playlist to clients, though: VideoController generates
      # its own #EXT-X-PLAYLIST-TYPE:VOD playlist from the source's known
      # runtime (Hivefin.Playback.Hls.Playlist), so hls.js sees a finite
      # movie instead of a live stream and doesn't chase a live edge. Leave
      # this flag as `event` — ffmpeg must keep writing segments
      # continuously regardless of what we serve.
      "-hls_playlist_type",
      "event",
      # temp_file: write to `<segment>.tmp` and rename on completion. Without
      # it, ffmpeg 5.1 (production image) opens the final filename at
      # segment start and flushes through a small buffer, so a client
      # requesting a segment mid-write gets a truncated .ts —
      # DEMUXER_ERROR_COULD_NOT_PARSE, the exact bug this VOD playlist fixes.
      # Our dev ffmpeg (8.1) happens to buffer the whole segment before the
      # file appears, which hid this.
      "-hls_flags",
      "independent_segments+temp_file",
      "-hls_segment_type",
      segment_type
    ] ++
      fmp4_init ++
      [
        "-hls_segment_filename",
        segment_pattern,
        output
      ]
  end

  defp container_args(format, output, _opts) when format in ["mp4", "m4v", "mov"] do
    ["-f", "mp4", "-movflags", @fmp4_movflags, output]
  end

  defp container_args(format, output, _opts) when is_binary(format) do
    ["-f", format, output]
  end
end
