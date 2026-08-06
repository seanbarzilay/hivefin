defmodule Hivefin.Playback.DeviceProfile do
  @moduledoc """
  Parses Jellyfin `DeviceProfile` POST payloads into a normalized map used by
  `Hivefin.Playback.Decision`.

  v1 only extracts DirectPlay-related containers and codecs from
  `DirectPlayProfiles` entries with `Type` video (or omitted type).
  """

  @type t :: %{
          direct_play_containers: [String.t()],
          video_codecs: [String.t()],
          audio_codecs: [String.t()]
        }

  @doc """
  Permissive default used when the client omits a DeviceProfile.
  Covers the fixture mp4 (h264/aac) and common progressive containers.
  """
  def default do
    %{
      direct_play_containers: ~w(mp4 m4v mov webm),
      video_codecs: ~w(h264 hevc av1 vp8 vp9 mpeg4),
      audio_codecs: ~w(aac mp3 opus vorbis ac3 eac3 flac)
    }
  end

  @doc """
  Builds a profile from a PlaybackInfo request body map (string or atom keys).
  """
  def from_playback_info_body(body) when is_map(body) do
    body
    |> get_key(["DeviceProfile", "deviceProfile", :DeviceProfile, :deviceProfile])
    |> from_jellyfin()
  end

  def from_playback_info_body(_), do: default()

  @doc """
  Parses a Jellyfin DeviceProfile map into `t()`. Falls back to `default/0`.
  """
  def from_jellyfin(nil), do: default()
  def from_jellyfin(profile) when not is_map(profile), do: default()

  def from_jellyfin(profile) when is_map(profile) do
    profiles =
      get_key(profile, ["DirectPlayProfiles", "directPlayProfiles", :DirectPlayProfiles]) || []

    video_profiles =
      profiles
      |> List.wrap()
      |> Enum.filter(&video_profile?/1)

    if video_profiles == [] do
      default()
    else
      containers =
        video_profiles
        |> Enum.flat_map(&split_list(get_key(&1, ["Container", "container", :Container])))
        |> normalize_list()

      video_codecs =
        video_profiles
        |> Enum.flat_map(&split_list(get_key(&1, ["VideoCodec", "videoCodec", :VideoCodec])))
        |> normalize_list()

      audio_codecs =
        video_profiles
        |> Enum.flat_map(&split_list(get_key(&1, ["AudioCodec", "audioCodec", :AudioCodec])))
        |> normalize_list()

      # Empty codec lists mean "any" in Jellyfin DirectPlayProfiles.
      %{
        direct_play_containers:
          if(containers == [], do: default().direct_play_containers, else: containers),
        video_codecs: if(video_codecs == [], do: default().video_codecs, else: video_codecs),
        audio_codecs: if(audio_codecs == [], do: default().audio_codecs, else: audio_codecs)
      }
    end
  end

  defp video_profile?(profile) when is_map(profile) do
    case get_key(profile, ["Type", "type", :Type]) do
      nil -> true
      "" -> true
      type when is_binary(type) -> String.downcase(type) == "video"
      :Video -> true
      :video -> true
      _ -> false
    end
  end

  defp video_profile?(_), do: false

  defp split_list(nil), do: []
  defp split_list(""), do: []

  defp split_list(value) when is_binary(value) do
    value
    |> String.split([",", "|"], trim: true)
    |> Enum.map(&String.trim/1)
  end

  defp split_list(value) when is_list(value), do: Enum.flat_map(value, &split_list/1)
  defp split_list(_), do: []

  defp normalize_list(list) do
    list
    |> Enum.map(&String.downcase/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp get_key(map, keys) when is_map(map) do
    Enum.find_value(keys, fn key ->
      Map.get(map, key)
    end)
  end
end
