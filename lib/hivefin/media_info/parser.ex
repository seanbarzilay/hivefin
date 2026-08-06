defmodule Hivefin.MediaInfo.Parser do
  @moduledoc """
  Parses ffprobe JSON into domain-friendly format and stream maps.
  """

  @doc """
  Parses ffprobe JSON (map or decoded string) into:

      %{format: %{duration: float | nil, bit_rate: integer | nil, format_name: string | nil},
        streams: [%{index:, type:, codec:, ...}, ...]}
  """
  def parse(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, map} -> parse(map)
      {:error, reason} -> {:error, reason}
    end
  end

  def parse(%{} = data) do
    format = parse_format(Map.get(data, "format") || %{})

    streams =
      data
      |> Map.get("streams", [])
      |> Enum.map(&parse_stream/1)
      |> Enum.reject(&is_nil/1)

    {:ok, %{format: format, streams: streams}}
  end

  def parse(_), do: {:error, :invalid_probe_data}

  defp parse_format(format) when is_map(format) do
    %{
      duration: parse_float(format["duration"]),
      bit_rate: parse_int(format["bit_rate"]),
      format_name: format["format_name"]
    }
  end

  defp parse_stream(%{"codec_type" => codec_type} = stream) do
    type =
      case codec_type do
        "video" -> :video
        "audio" -> :audio
        "subtitle" -> :subtitle
        _ -> nil
      end

    if type do
      %{
        index: parse_int(stream["index"]) || 0,
        type: type,
        codec: stream["codec_name"],
        language: stream_language(stream),
        channels: parse_int(stream["channels"]),
        width: parse_int(stream["width"]),
        height: parse_int(stream["height"]),
        bit_rate: parse_int(stream["bit_rate"]),
        is_default: disposition_flag?(stream, "default"),
        is_forced: disposition_flag?(stream, "forced"),
        title: get_in(stream, ["tags", "title"])
      }
    end
  end

  defp parse_stream(_), do: nil

  defp stream_language(stream) do
    get_in(stream, ["tags", "language"]) || get_in(stream, ["tags", "LANGUAGE"])
  end

  defp disposition_flag?(stream, key) do
    case get_in(stream, ["disposition", key]) do
      1 -> true
      "1" -> true
      true -> true
      _ -> false
    end
  end

  defp parse_int(nil), do: nil
  defp parse_int(n) when is_integer(n), do: n

  defp parse_int(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp parse_int(_), do: nil

  defp parse_float(nil), do: nil
  defp parse_float(n) when is_float(n), do: n
  defp parse_float(n) when is_integer(n), do: n * 1.0

  defp parse_float(s) when is_binary(s) do
    case Float.parse(s) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp parse_float(_), do: nil
end
