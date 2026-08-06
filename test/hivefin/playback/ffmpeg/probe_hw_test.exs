defmodule Hivefin.Playback.FFmpeg.ProbeHwTest do
  use ExUnit.Case, async: true

  alias Hivefin.Playback.FFmpeg.ProbeHw

  @fixture_all """
  Encoders:
   V..... = Video
   ------
   V....D libx264              libx264 H.264 / AVC
   V....D h264_videotoolbox    VideoToolbox H.264 Encoder (codec h264)
   V....D h264_nvenc           NVIDIA NVENC H.264 encoder (codec h264)
   V....D h264_vaapi           H.264 (VAAPI) (codec h264)
  """

  @fixture_cpu_only """
  Encoders:
   V....D libx264              libx264 H.264 / AVC
   V....D libx265              libx265 H.265 / HEVC
  """

  @fixture_nvenc_only """
   V....D libx264              libx264
   V....D h264_nvenc           NVIDIA NVENC H.264 encoder
  """

  describe "parse_encoders/1 and available/1" do
    test "detects all HW encoders from fixture" do
      assert ProbeHw.available(@fixture_all) == %{
               videotoolbox: true,
               nvenc: true,
               vaapi: true
             }
    end

    test "cpu-only list yields all false" do
      assert ProbeHw.parse_encoders(@fixture_cpu_only) == %{
               videotoolbox: false,
               nvenc: false,
               vaapi: false
             }
    end

    test "partial detection" do
      assert ProbeHw.available(@fixture_nvenc_only) == %{
               videotoolbox: false,
               nvenc: true,
               vaapi: false
             }
    end
  end

  describe "pick/1" do
    test "auto prefers videotoolbox when available" do
      assert {:ok, :videotoolbox} =
               ProbeHw.pick(%{
                 hw_accel: :auto,
                 available: %{videotoolbox: true, nvenc: true, vaapi: true}
               })
    end

    test "auto falls through to nvenc then vaapi then libx264" do
      assert {:ok, :nvenc} =
               ProbeHw.pick(%{
                 hw_accel: :auto,
                 available: %{videotoolbox: false, nvenc: true, vaapi: true}
               })

      assert {:ok, :vaapi} =
               ProbeHw.pick(%{
                 hw_accel: :auto,
                 available: %{videotoolbox: false, nvenc: false, vaapi: true}
               })

      assert {:ok, :libx264} =
               ProbeHw.pick(%{
                 hw_accel: :auto,
                 available: %{videotoolbox: false, nvenc: false, vaapi: false}
               })
    end

    test "none forces libx264" do
      assert {:ok, :libx264} =
               ProbeHw.pick(%{
                 hw_accel: :none,
                 available: %{videotoolbox: true, nvenc: true, vaapi: true}
               })
    end

    test "forced encoder used when available" do
      assert {:ok, :nvenc} =
               ProbeHw.pick(%{
                 hw_accel: :nvenc,
                 available: %{videotoolbox: true, nvenc: true, vaapi: false}
               })
    end

    test "forced unavailable encoder falls back to libx264 when allowed" do
      assert {:ok, :libx264} =
               ProbeHw.pick(%{
                 hw_accel: :vaapi,
                 available: %{videotoolbox: false, nvenc: false, vaapi: false},
                 allow_cpu_fallback: true
               })
    end

    test "forced unavailable encoder fails closed when CPU fallback disabled" do
      assert {:error, :hw_unavailable} =
               ProbeHw.pick(%{
                 hw_accel: :nvenc,
                 available: %{videotoolbox: false, nvenc: false, vaapi: false},
                 allow_cpu_fallback: false
               })
    end

    test "auto with no HW fails closed when CPU fallback disabled" do
      assert {:error, :hw_unavailable} =
               ProbeHw.pick(%{
                 hw_accel: :auto,
                 available: %{videotoolbox: false, nvenc: false, vaapi: false},
                 allow_cpu_fallback: false
               })
    end

    test "string config values normalize" do
      assert {:ok, :libx264} =
               ProbeHw.pick(%{
                 hw_accel: "none",
                 available: %{videotoolbox: true, nvenc: false, vaapi: false}
               })
    end
  end
end
