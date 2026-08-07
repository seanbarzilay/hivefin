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

  @doc """
  Builds args for container remux (stream copy, no re-encode).

  ## Options
  - `:output` — path, `"pipe:1"`, or HLS playlist path
  - `:format` — `"mp4"` (default fragmented progressive), `"mpegts"`, or `"hls"`
  - `:hls_segment_pattern` — required when format is `"hls"`
  - `:hls_time` — segment duration seconds (default 2)
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
      "-sn"
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
  - `:hls_time` — segment duration seconds (default 2)
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
      "-i",
      input,
      "-map",
      "0:v:0",
      "-map",
      "0:a:0?"
    ]

    video = video_encode_args(encoder, video_bitrate)
    # VAAPI injects its own -vf chain; skip software scale on that path.
    # Always force 8-bit yuv420p so NVENC/libx264 accept 10-bit HDR sources.
    scale = if encoder == :vaapi, do: [], else: scale_args(height)
    audio = ["-c:a", "aac", "-ac", "2", "-b:a", audio_bitrate]
    out = container_args(format, output, opts)

    base ++ video ++ scale ++ audio ++ out
  end

  # Fixed GOP so -hls_time segments actually split near the target duration.
  defp video_encode_args(:libx264, _bitrate) do
    ["-c:v", "libx264", "-preset", "veryfast", "-crf", "23", "-g", "96", "-keyint_min", "96", "-sc_threshold", "0"]
  end

  defp video_encode_args(:videotoolbox, bitrate) do
    ["-c:v", "h264_videotoolbox", "-b:v", bitrate, "-g", "96"]
  end

  defp video_encode_args(:nvenc, bitrate) do
    ["-c:v", "h264_nvenc", "-preset", "p4", "-b:v", bitrate, "-g", "96", "-forced-idr", "1"]
  end

  defp video_encode_args(:vaapi, bitrate) do
    # Device selection is environment-dependent; keep args allowlisted/static.
    [
      "-vaapi_device",
      "/dev/dri/renderD128",
      "-vf",
      "format=nv12,hwupload",
      "-c:v",
      "h264_vaapi",
      "-b:v",
      bitrate
    ]
  end

  # Always convert to 8-bit 4:2:0 — required for h264_nvenc on 10-bit HEVC/HDR.
  defp scale_args(nil), do: ["-vf", "format=yuv420p"]

  defp scale_args(height) when is_integer(height) and height > 0,
    do: ["-vf", "scale=-2:#{height},format=yuv420p"]

  defp scale_args(_), do: ["-vf", "format=yuv420p"]

  defp container_args("hls", output, opts) do
    segment_pattern = Map.fetch!(opts, :hls_segment_pattern)
    hls_time = Map.get(opts, :hls_time, 4)

    [
      "-f",
      "hls",
      "-hls_time",
      Integer.to_string(hls_time),
      "-hls_list_size",
      "0",
      # EVENT: growing playlist without ENDLIST until FFmpeg exits — hls.js keeps polling.
      "-hls_playlist_type",
      "event",
      "-hls_flags",
      "independent_segments",
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
