defmodule Hivefin.Jellyfin.Dto.PlaybackInfo do
  @moduledoc """
  Builds Jellyfin PlaybackInfoResponse-shaped maps.

  Absolute filesystem paths are never included. Clients receive signed stream
  URLs (`DirectStreamUrl` / `TranscodingUrl`) instead.
  """

  alias Hivefin.Accounts.User
  alias Hivefin.Jellyfin.Dto.SdkRequired
  alias Hivefin.Jellyfin.Id
  alias Hivefin.Library.{Item, MediaSource, MediaStream}
  alias Hivefin.Playback.{Decision, DeviceProfile, StreamToken}

  @doc """
  Builds a PlaybackInfo response for an item with preloaded media sources.

  ## Options
  - `:device_profile` — normalized profile or raw Jellyfin DeviceProfile map
  - `:play_session_id` — optional; generated if omitted
  - `:browser_safe` — when true, ignore ExoPlayer MKV profiles; use HTML5-safe
    DirectPlay rules and force HLS re-encode (not stream-copy remux).
  - `:base_url` — public origin for absolute Path on DirectPlay only
  """
  def build(%Item{} = item, %User{} = user, opts \\ []) do
    browser_safe? = Keyword.get(opts, :browser_safe, false)
    base_url = opts |> Keyword.get(:base_url) |> normalize_base_url()

    client_profile =
      case Keyword.get(opts, :device_profile) do
        %{} = p ->
          if Map.has_key?(p, :direct_play_containers) or Map.has_key?(p, "direct_play_containers") do
            p
          else
            DeviceProfile.from_jellyfin(p)
          end

        _ ->
          DeviceProfile.default()
      end

    # HTML5 must not honor Android ExoPlayer MKV/HEVC DirectPlay profiles.
    profile = if browser_safe?, do: DeviceProfile.browser_html5(), else: client_profile

    sources =
      case Map.get(item, :media_sources) do
        %Ecto.Association.NotLoaded{} -> []
        list when is_list(list) -> list
        _ -> []
      end

    play_session_id = Keyword.get(opts, :play_session_id) || Ecto.UUID.generate()

    media_sources =
      Enum.map(sources, fn source ->
        from_media_source(source, item, user, profile, play_session_id, base_url, browser_safe?)
      end)

    %{
      "MediaSources" => media_sources,
      "PlaySessionId" => play_session_id
    }
  end

  defp from_media_source(
         %MediaSource{} = source,
         %Item{} = item,
         %User{} = user,
         profile,
         play_session_id,
         base_url,
         browser_safe?
       ) do
    {method, meta} = Decision.choose(source, profile)

    # Stream-copy remux of long-GOP MKV often downloads segs but never paints in
    # Android WebView. Force a full re-encode for browser-safe clients.
    {method, meta} =
      if browser_safe? and method in [:direct_stream, :transcode] do
        {:transcode, Map.put(meta, :reason, :browser_safe_transcode)}
      else
        {method, meta}
      end

    token = StreamToken.sign(user.id, item.id, source.id)

    streams =
      case Map.get(source, :media_streams) do
        %Ecto.Association.NotLoaded{} -> []
        list when is_list(list) -> list
        _ -> []
      end

    default_audio =
      streams
      |> Enum.find(fn s -> s.type == :audio and s.is_default end)
      |> then(fn
        nil -> Enum.find(streams, &(&1.type == :audio))
        s -> s
      end)

    default_audio_index = if default_audio, do: default_audio.index, else: nil

    # Advertise MediaSource.Id == Item.Id (Jellyfin primary-source convention).
    item_id_fmt = Id.format(item.id)

    # For remux/transcode, advertise the *output* streams (h264/aac at 0/1).
    reencoded? = method in [:direct_stream, :transcode]
    video = Enum.find(streams, &(&1.type == :video))

    {container, media_streams, audio_index} =
      if reencoded? do
        # Container stays the SOURCE container even when re-encoding, as upstream
        # Jellyfin does. The transcode shape is advertised by TranscodingContainer
        # ("ts") + TranscodingSubProtocol ("hls") instead, which is what clients
        # actually read. Reporting Container: "ts" made jellyfin-web treat the
        # stream as MPEG-TS and hand it to the native <video> element, which Chrome
        # cannot demux — PipelineStatus::DEMUXER_ERROR_COULD_NOT_PARSE, so hls.js
        # was never used. MediaStreams still describe the *output* (h264/aac at 0/1).
        {source.container, output_media_streams(video), 1}
      else
        {source.container, Enum.map(streams, &from_media_stream/1), default_audio_index}
      end

    base = %{
      "Id" => item_id_fmt,
      "ItemId" => item_id_fmt,
      "Name" => source.path && Path.basename(source.path),
      "Path" => nil,
      "Container" => container,
      "Size" => source.size,
      "Bitrate" => source.bitrate,
      "RunTimeTicks" => source.duration_ticks,
      # Protocol/Type and the required booleans come from SdkRequired.source/1.
      # Protocol stays "File" (a local library file) so Android ExoPlayer takes the
      # QueueManager FILE branch and builds getVideoStreamUrl(static=true).
      "DefaultAudioStreamIndex" => audio_index,
      # Explicit -1 so clients do not treat missing as index 0 (video).
      "DefaultSubtitleStreamIndex" => -1,
      "MediaStreams" => media_streams,
      "Formats" => [],
      # Object, not array: the SDK types this Map<String, String?> and real Jellyfin
      # returns {}. An array raises JsonDecodingException on Android.
      "RequiredHttpHeaders" => %{}
    }

    base
    |> put_play_method(method, item.id, source.id, token, play_session_id, meta, base_url)
    |> SdkRequired.source()
  end

  # Output of our remux/transcode pipeline: single video + stereo AAC audio.
  defp output_media_streams(video) do
    [
      %{
        "Index" => 0,
        "Type" => "Video",
        "Codec" => "h264",
        "Width" => video && video.width,
        "Height" => video && video.height,
        "IsDefault" => true,
        "DisplayTitle" => display_video_title(video)
      }
      |> SdkRequired.stream(),
      %{
        "Index" => 1,
        "Type" => "Audio",
        "Codec" => "aac",
        "Channels" => 2,
        "ChannelLayout" => "stereo",
        "SampleRate" => 48_000,
        "IsDefault" => true,
        "DisplayTitle" => "AAC - Stereo"
      }
      |> SdkRequired.stream()
    ]
  end

  defp display_video_title(%{height: h}) when is_integer(h) and h > 0, do: "h264 - #{h}p"
  defp display_video_title(_), do: "h264"

  defp put_play_method(base, :direct_play, item_id, source_id, token, _session, _meta, base_url) do
    rel = direct_stream_url(item_id, item_id, token, static: true)
    _ = source_id

    Map.merge(base, %{
      "SupportsDirectPlay" => true,
      "SupportsDirectStream" => true,
      "SupportsTranscoding" => true,
      "DirectStreamUrl" => rel,
      # Absolute Path helps jellyfin-web <video> DirectPlay; Android ExoPlayer with
      # Protocol=File builds its own Static=true stream URL and ignores Path.
      "Path" => absolutize(base_url, rel),
      "TranscodingUrl" => nil,
      # nil is dropped; SdkRequired restores the non-null "http" enum value.
      "TranscodingSubProtocol" => nil,
      "TranscodingContainer" => nil
    })
  end

  defp put_play_method(base, method, item_id, source_id, token, session, _meta, base_url)
       when method in [:direct_stream, :transcode] do
    _ = source_id
    _ = base_url
    # HLS MPEG-TS — Android ExoPlayer DeviceProfile TranscodingProfile is
    # container=ts, protocol=hls (QueueManager requires MediaStreamProtocol.HLS).
    # Relative TranscodingUrl is resolved via apiClient.createUrl().
    # Do NOT set StreamUrl (jellyfin-web short-circuits on it).
    rel = hls_url(item_id, item_id, token, session, transcode?: method == :transcode)

    Map.merge(base, %{
      "SupportsDirectPlay" => false,
      "SupportsDirectStream" => false,
      "SupportsTranscoding" => true,
      "DirectStreamUrl" => nil,
      "Path" => nil,
      "StreamUrl" => nil,
      "TranscodingUrl" => rel,
      "TranscodingSubProtocol" => "hls",
      "TranscodingContainer" => "ts"
    })
  end

  defp direct_stream_url(path_id, media_source_id, token, opts) do
    static = if Keyword.get(opts, :static, true), do: "true", else: "false"
    path_id = Id.format(path_id)
    media_source_id = Id.format(media_source_id)

    "/Videos/#{path_id}/stream?MediaSourceId=#{encode(media_source_id)}&Static=#{static}&api_key=#{encode(token)}"
  end

  defp hls_url(item_id, media_source_id, token, session, opts) do
    item_id = Id.format(item_id)
    media_source_id = Id.format(media_source_id)
    transcode = if Keyword.get(opts, :transcode?, false), do: "&Transcode=true", else: ""

    "/Videos/#{item_id}/master.m3u8?MediaSourceId=#{encode(media_source_id)}&PlaySessionId=#{encode(session)}&api_key=#{encode(token)}&Static=false#{transcode}"
  end

  defp normalize_base_url(nil), do: nil
  defp normalize_base_url(""), do: nil

  defp normalize_base_url(url) when is_binary(url) do
    url |> String.trim() |> String.trim_trailing("/")
  end

  defp absolutize(nil, path), do: path
  defp absolutize("", path), do: path

  defp absolutize(base, path) when is_binary(base) and is_binary(path) do
    if String.starts_with?(path, "http://") or String.starts_with?(path, "https://") do
      path
    else
      base <> path
    end
  end

  defp from_media_stream(%MediaStream{} = stream) do
    %{
      "Index" => stream.index,
      "Type" => stream_type_name(stream.type),
      "Codec" => stream.codec,
      "Language" => stream.language,
      "Channels" => stream.channels,
      "Width" => stream.width,
      "Height" => stream.height,
      "BitRate" => stream.bit_rate,
      "IsDefault" => stream.is_default,
      "IsForced" => stream.is_forced,
      "IsTextSubtitleStream" => stream.type == :subtitle,
      "Title" => stream.title
    }
    |> SdkRequired.stream()
  end

  defp stream_type_name(:video), do: "Video"
  defp stream_type_name(:audio), do: "Audio"
  defp stream_type_name(:subtitle), do: "Subtitle"

  defp stream_type_name(other) when is_atom(other),
    do: other |> Atom.to_string() |> Macro.camelize()

  defp encode(value) when is_binary(value), do: URI.encode_www_form(value)
end
