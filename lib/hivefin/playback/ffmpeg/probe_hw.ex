defmodule Hivefin.Playback.FFmpeg.ProbeHw do
  @moduledoc """
  Detects hardware H.264 encoders advertised by `ffmpeg -encoders`.

  Prefer injecting encoder-list text in tests via `available/1` or
  `parse_encoders/1` so unit tests never spawn FFmpeg.
  """

  @type encoder :: :videotoolbox | :nvenc | :vaapi | :libx264

  @type availability :: %{
          videotoolbox: boolean(),
          nvenc: boolean(),
          vaapi: boolean()
        }

  @encoder_markers %{
    videotoolbox: "h264_videotoolbox",
    nvenc: "h264_nvenc",
    vaapi: "h264_vaapi"
  }

  @doc """
  Probes the configured ffmpeg binary for HW H.264 encoders.

  When `encoder_list` is a binary (tests), parses that string instead of
  spawning ffmpeg.
  """
  @spec available(String.t() | nil) :: availability()
  def available(encoder_list \\ nil)

  def available(encoder_list) when is_binary(encoder_list) do
    parse_encoders(encoder_list)
  end

  def available(nil) do
    case run_encoders() do
      {:ok, output} -> parse_encoders(output)
      {:error, _} -> %{videotoolbox: false, nvenc: false, vaapi: false}
    end
  end

  @doc """
  Parses `ffmpeg -encoders` stdout into availability flags.
  """
  @spec parse_encoders(String.t()) :: availability()
  def parse_encoders(output) when is_binary(output) do
    Map.new(@encoder_markers, fn {key, marker} ->
      {key, String.contains?(output, marker)}
    end)
  end

  @doc """
  Picks an encoder from config and availability.

  ## Config keys (map or keyword)
  - `:hw_accel` — `:auto | :videotoolbox | :nvenc | :vaapi | :none` (default `:auto`)
  - `:available` — optional availability map; defaults to `available/0`
  - `:prefer` — optional ordered list of HW encoders for `:auto`

  Forced HW that is unavailable falls through to `:libx264`.
  `:none` always returns `:libx264`.
  """
  @spec pick(map() | keyword()) :: encoder()
  def pick(config \\ %{})

  def pick(config) when is_list(config), do: pick(Map.new(config))

  def pick(config) when is_map(config) do
    hw_accel = normalize_hw(Map.get(config, :hw_accel) || Map.get(config, "hw_accel") || :auto)

    avail =
      Map.get(config, :available) ||
        Map.get(config, "available") ||
        available()

    prefer =
      Map.get(config, :prefer) ||
        default_prefer_order()

    case hw_accel do
      :none ->
        :libx264

      :auto ->
        Enum.find_value(prefer, :libx264, fn enc ->
          if Map.get(avail, enc, false), do: enc
        end)

      forced when forced in [:videotoolbox, :nvenc, :vaapi] ->
        if Map.get(avail, forced, false), do: forced, else: :libx264
    end
  end

  @doc """
  Reads HW accel preference from application env (`:hw_accel`).
  """
  @spec config_hw_accel() :: :auto | :videotoolbox | :nvenc | :vaapi | :none
  def config_hw_accel do
    Application.get_env(:hivefin, :hw_accel, :auto)
    |> normalize_hw()
  end

  defp run_encoders do
    ffmpeg = ffmpeg_path()

    case System.cmd(ffmpeg, ["-hide_banner", "-encoders"], stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, code} -> {:error, {:ffmpeg_encoders_failed, code, String.trim(output)}}
    end
  rescue
    e in ErlangError ->
      {:error, {:ffmpeg_exec, e}}
  end

  defp ffmpeg_path do
    Application.get_env(:hivefin, :ffmpeg_path) ||
      System.find_executable("ffmpeg") ||
      "ffmpeg"
  end

  defp default_prefer_order do
    # macOS VideoToolbox first; then discrete NVIDIA; then VAAPI.
    [:videotoolbox, :nvenc, :vaapi]
  end

  defp normalize_hw(v) when v in [:auto, :videotoolbox, :nvenc, :vaapi, :none], do: v

  defp normalize_hw(v) when is_binary(v) do
    case String.downcase(String.trim(v)) do
      "auto" -> :auto
      "videotoolbox" -> :videotoolbox
      "nvenc" -> :nvenc
      "vaapi" -> :vaapi
      "none" -> :none
      "cpu" -> :none
      "libx264" -> :none
      _ -> :auto
    end
  end

  defp normalize_hw(_), do: :auto
end
