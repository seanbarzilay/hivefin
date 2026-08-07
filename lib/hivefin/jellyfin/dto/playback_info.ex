defmodule Hivefin.Jellyfin.Dto.PlaybackInfo do
  @moduledoc """
  Builds Jellyfin PlaybackInfoResponse-shaped maps.

  Absolute filesystem paths are never included. Clients receive signed stream
  URLs (`DirectStreamUrl` / `TranscodingUrl`) instead.
  """

  alias Hivefin.Accounts.User
  alias Hivefin.Jellyfin.Id
  alias Hivefin.Library.{Item, MediaSource, MediaStream}
  alias Hivefin.Playback.{Decision, DeviceProfile, StreamToken}


  @doc """
  Builds a PlaybackInfo response for an item with preloaded media sources.

  ## Options
  - `:device_profile` — normalized profile or raw Jellyfin DeviceProfile map
  - `:play_session_id` — optional; generated if omitted
  - `:stream_format` — `:hls` (default, jellyfin-vue) or `:progressive`
    (jellyfin-web / Android WebView — native `<video>` progressive MP4)
  """
  def build(%Item{} = item, %User{} = user, opts \\ []) do
    profile =
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

    stream_format = Keyword.get(opts, :stream_format, :hls)

    sources =
      case Map.get(item, :media_sources) do
        %Ecto.Association.NotLoaded{} -> []
        list when is_list(list) -> list
        _ -> []
      end

    play_session_id = Keyword.get(opts, :play_session_id) || Ecto.UUID.generate()

    media_sources =
      Enum.map(sources, fn source ->
        from_media_source(source, item, user, profile, play_session_id, stream_format)
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
         stream_format
       ) do
    {method, meta} = Decision.choose(source, profile)
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
    # Keep signing tokens with the real DB source id for path resolution.
    item_id_fmt = Id.format(item.id)

    base = %{
      "Id" => item_id_fmt,
      "ItemId" => item_id_fmt,
      "Name" => source.path && Path.basename(source.path),
      "Path" => nil,
      "Container" => source.container,
      "Size" => source.size,
      "Bitrate" => source.bitrate,
      "RunTimeTicks" => source.duration_ticks,
      "Type" => "Default",
      "Protocol" => "Http",
      "ReadAtNativeFramerate" => false,
      "IgnoreDts" => false,
      "IgnoreIndex" => false,
      "GenPtsInput" => false,
      "SupportsProbing" => true,
      "DefaultAudioStreamIndex" => default_audio_index,
      "MediaStreams" => Enum.map(streams, &from_media_stream/1),
      "Formats" => [],
      "RequiredHttpHeaders" => %{}
    }

    base
    |> put_play_method(method, item.id, source.id, token, play_session_id, meta, stream_format)
    |> drop_nils()
  end

  defp put_play_method(base, :direct_play, item_id, source_id, token, _session, _meta, _fmt) do
    # jellyfin-web builds Videos/{itemId}/stream itself; still provide a
    # DirectStreamUrl for SDK clients. Path uses item id (JF convention).
    url = direct_stream_url(item_id, item_id, token, static: true)
    _ = source_id

    Map.merge(base, %{
      "SupportsDirectPlay" => true,
      "SupportsDirectStream" => true,
      "SupportsTranscoding" => true,
      "DirectStreamUrl" => url,
      # No TranscodingUrl while DirectPlay is selected; remux/transcode only when
      # Decision rejects DirectPlay for this profile.
      "TranscodingUrl" => nil,
      "TranscodingSubProtocol" => nil,
      "TranscodingContainer" => nil,
      "IsRemote" => false
    })
  end

  defp put_play_method(base, :direct_stream, item_id, source_id, token, session, _meta, stream_format) do
    # Remux when container is wrong but codecs are OK.
    # SupportsDirectStream stays false: vue treats true as Static=true original.
    _ = source_id
    non_direct_play_urls(base, item_id, token, session, stream_format, transcode?: false)
  end

  defp put_play_method(base, :transcode, item_id, source_id, token, session, _meta, stream_format) do
    # Re-encode when codecs are not DirectPlay-compatible.
    _ = source_id
    non_direct_play_urls(base, item_id, token, session, stream_format, transcode?: true)
  end

  # jellyfin-vue → HLS (hls.js). jellyfin-web/Android WebView → progressive MP4
  # (native <video> src; HLS often never issues a network request in that shell).
  defp non_direct_play_urls(base, item_id, token, session, :progressive, opts) do
    url = progressive_url(item_id, item_id, token, session, opts)

    Map.merge(base, %{
      "SupportsDirectPlay" => false,
      "SupportsDirectStream" => false,
      "SupportsTranscoding" => true,
      "DirectStreamUrl" => nil,
      "TranscodingUrl" => url,
      "TranscodingSubProtocol" => "http",
      "TranscodingContainer" => "mp4",
      "IsRemote" => false
    })
  end

  defp non_direct_play_urls(base, item_id, token, session, _hls, opts) do
    url = hls_url(item_id, item_id, token, session, opts)

    Map.merge(base, %{
      "SupportsDirectPlay" => false,
      "SupportsDirectStream" => false,
      "SupportsTranscoding" => true,
      "DirectStreamUrl" => nil,
      "TranscodingUrl" => url,
      "TranscodingSubProtocol" => "hls",
      "TranscodingContainer" => "ts",
      "IsRemote" => false
    })
  end

  defp direct_stream_url(path_id, media_source_id, token, opts) do
    static = if Keyword.get(opts, :static, true), do: "true", else: "false"
    path_id = Id.format(path_id)
    media_source_id = Id.format(media_source_id)

    "/Videos/#{path_id}/stream?MediaSourceId=#{encode(media_source_id)}&Static=#{static}&api_key=#{encode(token)}"
  end

  defp progressive_url(item_id, media_source_id, token, session, opts) do
    item_id = Id.format(item_id)
    media_source_id = Id.format(media_source_id)
    transcode = if Keyword.get(opts, :transcode?, false), do: "&Transcode=true", else: ""

    "/Videos/#{item_id}/stream.mp4?MediaSourceId=#{encode(media_source_id)}&PlaySessionId=#{encode(session)}&api_key=#{encode(token)}&Static=false#{transcode}"
  end

  defp hls_url(item_id, media_source_id, token, session, opts) do
    item_id = Id.format(item_id)
    media_source_id = Id.format(media_source_id)
    transcode = if Keyword.get(opts, :transcode?, false), do: "&Transcode=true", else: ""

    "/Videos/#{item_id}/master.m3u8?MediaSourceId=#{encode(media_source_id)}&PlaySessionId=#{encode(session)}&api_key=#{encode(token)}&Static=false#{transcode}"
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
      "Title" => stream.title
    }
    |> drop_nils()
  end

  defp stream_type_name(:video), do: "Video"
  defp stream_type_name(:audio), do: "Audio"
  defp stream_type_name(:subtitle), do: "Subtitle"

  defp stream_type_name(other) when is_atom(other),
    do: other |> Atom.to_string() |> Macro.camelize()

  defp encode(value) when is_binary(value), do: URI.encode_www_form(value)

  defp drop_nils(map) do
    map
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end
end
