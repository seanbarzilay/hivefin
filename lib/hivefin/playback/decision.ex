defmodule Hivefin.Playback.Decision do
  @moduledoc """
  Chooses DirectPlay / DirectStream (remux) / Transcode for a media source
  against a normalized `DeviceProfile`.

  ## v1 heuristics

  1. If container is allowed **and** primary video/audio codecs are allowed →
     `:direct_play`
  2. Else if codecs are allowed but container is not → `:direct_stream` (remux)
  3. Else → `:transcode`

  Empty allow-lists mean **any** (Jellyfin DirectPlayProfile semantics).
  Missing video/audio streams are treated as "no restriction" for that type.
  """

  alias Hivefin.Library.MediaSource
  alias Hivefin.Playback.DeviceProfile

  @type method :: :direct_play | :direct_stream | :transcode

  @type source_input :: MediaSource.t() | map()

  @type profile :: DeviceProfile.t() | map()

  @type meta :: %{
          required(:reason) => atom(),
          optional(:remux_container) => String.t(),
          optional(:implemented) => boolean(),
          optional(:video_codec) => String.t() | nil,
          optional(:audio_codec) => String.t() | nil,
          optional(:container) => String.t() | nil
        }

  @doc """
  Returns `{method, meta}` for the given source and profile.
  """
  @spec choose(source_input(), profile()) :: {method(), meta()}
  def choose(source, profile) do
    %{container: container, video_codec: video, audio_codec: audio} = normalize_source(source)
    profile = normalize_profile(profile)

    codecs_ok? =
      codec_allowed?(video, profile.video_codecs) and codec_allowed?(audio, profile.audio_codecs)

    container_ok? = container_allowed?(container, profile.direct_play_containers)

    cond do
      codecs_ok? and container_ok? ->
        {:direct_play,
         %{
           reason: :compatible,
           container: container,
           video_codec: video,
           audio_codec: audio
         }}

      codecs_ok? ->
        {:direct_stream,
         %{
           reason: :container_not_allowed,
           remux_container: "ts",
           # Remux runner lands in Task 8; decision + URL surface here.
           implemented: false,
           container: container,
           video_codec: video,
           audio_codec: audio
         }}

      not codec_allowed?(video, profile.video_codecs) ->
        {:transcode,
         %{
           reason: :video_codec_not_allowed,
           implemented: false,
           container: container,
           video_codec: video,
           audio_codec: audio
         }}

      not codec_allowed?(audio, profile.audio_codecs) ->
        {:transcode,
         %{
           reason: :audio_codec_not_allowed,
           implemented: false,
           container: container,
           video_codec: video,
           audio_codec: audio
         }}

      true ->
        {:transcode,
         %{
           reason: :incompatible,
           implemented: false,
           container: container,
           video_codec: video,
           audio_codec: audio
         }}
    end
  end

  defp normalize_profile(%{direct_play_containers: c, video_codecs: v, audio_codecs: a}) do
    %{
      direct_play_containers: Enum.map(List.wrap(c), &String.downcase/1),
      video_codecs: Enum.map(List.wrap(v), &String.downcase/1),
      audio_codecs: Enum.map(List.wrap(a), &String.downcase/1)
    }
  end

  defp normalize_profile(_), do: DeviceProfile.default()

  defp normalize_source(%MediaSource{} = source) do
    streams =
      case Map.get(source, :media_streams) do
        %Ecto.Association.NotLoaded{} -> []
        list when is_list(list) -> list
        _ -> []
      end

    %{
      container: downcase_or_nil(source.container),
      video_codec: first_codec(streams, :video),
      audio_codec: first_codec(streams, :audio)
    }
  end

  defp normalize_source(%{} = source) do
    streams = Map.get(source, :media_streams) || Map.get(source, "media_streams") || []

    video =
      Map.get(source, :video_codec) ||
        Map.get(source, "video_codec") ||
        first_codec(streams, :video)

    audio =
      Map.get(source, :audio_codec) ||
        Map.get(source, "audio_codec") ||
        first_codec(streams, :audio)

    container =
      Map.get(source, :container) ||
        Map.get(source, "container")

    %{
      container: downcase_or_nil(container),
      video_codec: downcase_or_nil(video),
      audio_codec: downcase_or_nil(audio)
    }
  end

  defp first_codec(streams, type) when is_list(streams) do
    streams
    |> Enum.find(fn s ->
      stream_type(s) == type
    end)
    |> case do
      nil -> nil
      s -> downcase_or_nil(Map.get(s, :codec) || Map.get(s, "codec"))
    end
  end

  defp first_codec(_, _), do: nil

  defp stream_type(%{type: type}), do: type
  defp stream_type(%{"type" => type}) when is_atom(type), do: type

  defp stream_type(%{"type" => type}) when is_binary(type) do
    case String.downcase(type) do
      "video" -> :video
      "audio" -> :audio
      "subtitle" -> :subtitle
      _ -> nil
    end
  end

  defp stream_type(_), do: nil

  # Empty allow-list = any container (including unknown/nil).
  defp container_allowed?(_container, []), do: true
  defp container_allowed?(nil, _allowed), do: false

  defp container_allowed?(container, allowed) do
    container = String.downcase(container)
    Enum.any?(allowed, fn a -> a == container end)
  end

  # nil codec = unknown/missing → allow (e.g. audio-less clips)
  # empty allow-list = any codec
  defp codec_allowed?(nil, _allowed), do: true
  defp codec_allowed?(_codec, []), do: true

  defp codec_allowed?(codec, allowed) do
    codec = String.downcase(codec)
    Enum.any?(allowed, fn a -> a == codec end)
  end

  defp downcase_or_nil(nil), do: nil
  defp downcase_or_nil(v) when is_binary(v), do: String.downcase(v)
  defp downcase_or_nil(v), do: v
end
