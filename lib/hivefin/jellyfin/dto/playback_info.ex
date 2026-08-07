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
  - `:browser_safe` — when true, ignore ExoPlayer MKV profiles; use HTML5-safe
    DirectPlay rules and HLS for remux/transcode
  - `:base_url` — public origin for absolute StreamUrl helpers
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

    # HTML5/hls.js needs keyframe-aligned segments. Stream-copy remux of long-GOP
    # H.264 MKV often downloads segs but never paints (stuck UI) in Android WebView.
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
      # Array so jellyfin-web `RequiredHttpHeaders.length` works (object has no length).
      "RequiredHttpHeaders" => []
    }

    base
    |> put_play_method(method, item.id, source.id, token, play_session_id, meta, base_url)
    |> drop_nils()
  end

  defp put_play_method(base, :direct_play, item_id, source_id, token, _session, _meta, base_url) do
    rel = direct_stream_url(item_id, item_id, token, static: true)
    _ = source_id

    Map.merge(base, %{
      "SupportsDirectPlay" => true,
      "SupportsDirectStream" => true,
      "SupportsTranscoding" => true,
      "DirectStreamUrl" => rel,
      "StreamUrl" => absolutize(base_url, rel),
      # Only set Path for true DirectPlay of browser-safe files.
      "Path" => absolutize(base_url, rel),
      "TranscodingUrl" => nil,
      "TranscodingSubProtocol" => nil,
      "TranscodingContainer" => nil,
      "IsRemote" => false
    })
  end

  defp put_play_method(base, method, item_id, source_id, token, session, _meta, base_url)
       when method in [:direct_stream, :transcode] do
    _ = source_id
    # Always HLS for remux/transcode. Progressive fMP4 is aborted by browsers
    # after ~1s (range probes / incomplete timeline) — broken pipe in FFmpeg.
    rel = hls_url(item_id, item_id, token, session, transcode?: method == :transcode)
    abs = absolutize(base_url, rel)

    Map.merge(base, %{
      "SupportsDirectPlay" => false,
      "SupportsDirectStream" => false,
      "SupportsTranscoding" => true,
      "DirectStreamUrl" => nil,
      # Do not put m3u8 in Path — DirectPlay Path is for progressive files only.
      "Path" => nil,
      # Absolute StreamUrl for native Android ExoPlayer; relative TranscodingUrl
      # for jellyfin-web getUrl() (which prefixes serverAddress).
      "StreamUrl" => abs,
      "TranscodingUrl" => rel,
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
