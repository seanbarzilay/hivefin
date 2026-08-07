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

    sources =
      case Map.get(item, :media_sources) do
        %Ecto.Association.NotLoaded{} -> []
        list when is_list(list) -> list
        _ -> []
      end

    play_session_id = Keyword.get(opts, :play_session_id) || Ecto.UUID.generate()

    media_sources =
      Enum.map(sources, fn source ->
        from_media_source(source, item, user, profile, play_session_id)
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
         play_session_id
       ) do
    {method, meta} = Decision.choose(source, profile)
    token = StreamToken.sign(user.id, item.id, source.id)

    streams =
      case Map.get(source, :media_streams) do
        %Ecto.Association.NotLoaded{} -> []
        list when is_list(list) -> list
        _ -> []
      end

    base = %{
      "Id" => Id.format(source.id),
      "ItemId" => Id.format(item.id),
      "Container" => source.container,
      "Size" => source.size,
      "Bitrate" => source.bitrate,
      "RunTimeTicks" => source.duration_ticks,
      "Type" => "Default",
      "Protocol" => "Http",
      "ReadAtNativeFramerate" => false,
      "MediaStreams" => Enum.map(streams, &from_media_stream/1),
      "Formats" => [],
      "RequiredHttpHeaders" => %{}
    }

    base
    |> put_play_method(method, item.id, source.id, token, play_session_id, meta)
    |> drop_nils()
  end

  defp put_play_method(base, :direct_play, _item_id, source_id, token, _session, _meta) do
    # Original file (incl. MKV) when the device profile allows DirectPlay.
    # jellyfin-vue builds /Videos/{mediaSourceId}/stream.{Container}?Static=true
    # when SupportsDirectStream is true.
    url = direct_stream_url(source_id, source_id, token, static: true)

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

  defp put_play_method(base, :direct_stream, item_id, source_id, token, session, _meta) do
    # Remux only when DirectPlay is not allowed. jellyfin-vue always feeds
    # non-DirectPlay URLs into hls.js, so this must be HLS (not progressive MP4).
    # SupportsDirectStream stays false: vue treats it as Static=true original file.
    url = hls_url(item_id, source_id, token, session, transcode: false)

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

  defp put_play_method(base, :transcode, item_id, source_id, token, session, _meta) do
    # Re-encode only when codecs are not DirectPlay-compatible.
    # Must be HLS for jellyfin-vue (hls.js on every non-DirectPlay URL).
    url = hls_url(item_id, source_id, token, session, transcode: true)

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

  defp direct_stream_url(path_id, source_id, token, opts) do
    static = if Keyword.get(opts, :static, true), do: "true", else: "false"
    path_id = Id.format(path_id)
    source_id = Id.format(source_id)

    "/Videos/#{path_id}/stream?MediaSourceId=#{encode(source_id)}&Static=#{static}&api_key=#{encode(token)}"
  end

  defp progressive_url(item_id, source_id, token, session, opts) do
    item_id = Id.format(item_id)
    source_id = Id.format(source_id)
    transcode = if Keyword.get(opts, :transcode, false), do: "&Transcode=true", else: ""

    "/Videos/#{item_id}/stream.mp4?MediaSourceId=#{encode(source_id)}&PlaySessionId=#{encode(session)}&api_key=#{encode(token)}&Static=false#{transcode}"
  end

  defp hls_url(item_id, source_id, token, session, opts) do
    item_id = Id.format(item_id)
    source_id = Id.format(source_id)
    transcode = if Keyword.get(opts, :transcode, false), do: "&Transcode=true", else: ""

    "/Videos/#{item_id}/master.m3u8?MediaSourceId=#{encode(source_id)}&PlaySessionId=#{encode(session)}&api_key=#{encode(token)}&Static=false#{transcode}"
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
