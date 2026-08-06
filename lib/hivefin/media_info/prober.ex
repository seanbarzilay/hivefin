defmodule Hivefin.MediaInfo.Prober do
  @moduledoc """
  Thin wrapper around the `ffprobe` binary.
  """

  alias Hivefin.MediaInfo.Parser

  @doc """
  Probes a media file and returns format + stream metadata.

      MediaInfo.Prober.probe(path) ::
        {:ok, %{format: map(), streams: [map()]}} | {:error, term()}
  """
  def probe(path) when is_binary(path) do
    path = Path.expand(path)

    with :ok <- ensure_file(path),
         {:ok, json} <- run_ffprobe(path) do
      Parser.parse(json)
    end
  end

  defp ensure_file(path) do
    if File.regular?(path), do: :ok, else: {:error, :enoent}
  end

  defp run_ffprobe(path) do
    ffprobe = ffprobe_path()

    args = [
      "-v",
      "quiet",
      "-print_format",
      "json",
      "-show_format",
      "-show_streams",
      path
    ]

    case System.cmd(ffprobe, args, stderr_to_stdout: true) do
      {output, 0} ->
        {:ok, output}

      {output, code} ->
        {:error, {:ffprobe_failed, code, String.trim(output)}}
    end
  rescue
    e in ErlangError ->
      {:error, {:ffprobe_exec, e}}
  end

  defp ffprobe_path do
    Application.get_env(:hivefin, :ffprobe_path) ||
      System.find_executable("ffprobe") ||
      "ffprobe"
  end
end
