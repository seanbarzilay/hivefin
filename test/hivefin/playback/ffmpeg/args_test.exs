defmodule Hivefin.Playback.FFmpeg.ArgsTest do
  use ExUnit.Case, async: true

  alias Hivefin.Playback.FFmpeg.Args

  describe "remux/2" do
    test "stream-copies to fragmented mp4 pipe by default" do
      args = Args.remux("/media/in.mkv", %{output: "pipe:1"})

      assert args == [
               "-hide_banner",
               "-loglevel",
               "error",
               "-nostdin",
               "-fflags",
               "+genpts",
               "-i",
               "/media/in.mkv",
               "-map",
               "0:v:0",
               "-map",
               "0:a:0?",
               "-c",
               "copy",
               "-dn",
               "-sn",
               "-start_at_zero",
               "-copyts",
               "-avoid_negative_ts",
               "make_zero",
               "-f",
               "mp4",
               "-movflags",
               "frag_keyframe+empty_moov+default_base_moof",
               "pipe:1"
             ]
    end

    test "remux to hls includes segment pattern" do
      args =
        Args.remux("/in.mkv", %{
          output: "/tmp/index.m3u8",
          format: "hls",
          hls_segment_pattern: "/tmp/seg_%03d.ts"
        })

      assert "hls" in args
      assert "-hls_segment_filename" in args
      assert "/tmp/seg_%03d.ts" in args
    end

    test "allows custom output path and format" do
      args = Args.remux("/in.mp4", %{output: "/tmp/out.ts", format: "mpegts"})
      assert Enum.at(args, -1) == "/tmp/out.ts"
      assert "-c" in args
      assert "copy" in args
      assert "mpegts" in args
    end
  end

  describe "transcode/2" do
    test "libx264 progressive fMP4 with scale and yuv420p" do
      args =
        Args.transcode("/media/in.mkv", %{
          encoder: :libx264,
          output: "pipe:1",
          height: 720
        })

      assert "-c:v" in args
      assert "libx264" in args
      assert "-preset" in args
      assert "veryfast" in args
      assert "-crf" in args
      assert "23" in args
      assert "-vf" in args
      assert "setpts=PTS-STARTPTS,scale=-2:720,format=yuv420p" in args
      assert "-c:a" in args
      assert "aac" in args
      assert "-af" in args
      assert "aresample=async=1:first_pts=0,asetpts=PTS-STARTPTS" in args
      assert "-f" in args
      assert "mp4" in args
      assert "-movflags" in args
      assert Enum.at(args, -1) == "pipe:1"
      refute "h264_videotoolbox" in args
    end

    test "videotoolbox uses bitrate not crf" do
      args =
        Args.transcode("/in.mp4", %{
          encoder: :videotoolbox,
          output: "pipe:1",
          height: 720
        })

      assert "h264_videotoolbox" in args
      assert "-b:v" in args
      assert "4M" in args
      refute "libx264" in args
      refute "-crf" in args
    end

    test "nvenc encoder name" do
      args = Args.transcode("/in.mp4", %{encoder: :nvenc, output: "pipe:1"})
      assert "h264_nvenc" in args
    end

    test "vaapi encoder name and device" do
      args = Args.transcode("/in.mp4", %{encoder: :vaapi, output: "pipe:1"})
      assert "h264_vaapi" in args
      assert "/dev/dri/renderD128" in args
    end

    test "hls output includes segment pattern" do
      args =
        Args.transcode("/in.mp4", %{
          encoder: :libx264,
          output: "/tmp/session/index.m3u8",
          format: "hls",
          hls_segment_pattern: "/tmp/session/seg_%03d.ts",
          height: 480
        })

      assert "hls" in args
      assert "-hls_segment_filename" in args
      assert "/tmp/session/seg_%03d.ts" in args
      assert Enum.at(args, -1) == "/tmp/session/index.m3u8"
    end

    test "never includes arbitrary filter from unknown keys" do
      # Only allowlisted opts are read; garbage keys are ignored.
      args =
        Args.transcode("/in.mp4", %{
          encoder: :libx264,
          output: "pipe:1",
          client_filter: "movie=/etc/passwd"
        })

      refute Enum.any?(args, &String.contains?(&1, "/etc/passwd"))
      refute "movie=/etc/passwd" in args
    end
  end
end
