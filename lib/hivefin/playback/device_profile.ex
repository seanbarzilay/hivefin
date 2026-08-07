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

  DirectPlay is preferred (including `mkv`, which is most of a typical
  library). Remux/transcode only kick in when a real client DeviceProfile
  rejects the container or codecs.
  """
  def default do
    %{
      direct_play_containers: ~w(mp4 m4v mov webm mkv ts m2ts avi wmv),
      video_codecs: ~w(h264 hevc av1 vp8 vp9 mpeg2video mpeg4 vc1),
      audio_codecs: ~w(aac mp3 opus vorbis ac3 eac3 flac dts truehd pcm_s16le pcm_s24le pcm_s32le)
    }
  end

  @doc """
  What a browser `<video>` element can actually progressive-play.

  Android/official app DeviceProfiles allow MKV/HEVC for ExoPlayer, but the
  embedded jellyfin-web player is HTML5 — DirectPlaying MKV never loads and
  stalls at 00:00. Use this profile for jellyfin-web / progressive clients.
  """
  def browser_html5 do
    %{
      direct_play_containers: ~w(mp4 m4v webm mov),
      video_codecs: ~w(h264 avc avc1 vp8 vp9 av1),
      audio_codecs: ~w(aac mp3 opus vorbis flac)
    }
  end

  @doc """
  Builds a profile from a PlaybackInfo request body map (string or atom keys).

  Accepts both flat bodies (`{"DeviceProfile": ...}`) and Jellyfin SDK shapes
  (`{"playbackInfoDto": {"DeviceProfile": ...}}`). Mis-parsing used to fall
  through to `default/0`, which DirectPlays MKV — wrong for web clients that
  sent a restrictive profile nested under `playbackInfoDto`.
  """
  def from_playback_info_body(body) when is_map(body) do
    body
    |> extract_device_profile()
    |> from_jellyfin()
  end

  def from_playback_info_body(_), do: default()

  defp extract_device_profile(body) when is_map(body) do
    get_key(body, ["DeviceProfile", "deviceProfile", :DeviceProfile, :deviceProfile]) ||
      nested_device_profile(body, ["playbackInfoDto", "PlaybackInfoDto", :playbackInfoDto]) ||
      nested_device_profile(body, ["dto", "Dto"])
  end

  defp nested_device_profile(body, wrapper_keys) do
    case get_key(body, wrapper_keys) do
      %{} = inner ->
        get_key(inner, ["DeviceProfile", "deviceProfile", :DeviceProfile, :deviceProfile])

      _ ->
        nil
    end
  end

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

      # Empty lists mean "any" in Jellyfin DirectPlayProfiles — keep them empty.
      # Decision treats [] for containers/codecs as allow-all.
      %{
        direct_play_containers: containers,
        video_codecs: video_codecs,
        audio_codecs: audio_codecs
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
