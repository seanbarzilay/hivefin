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
    # Path uses media source id (jellyfin-vue convention)
    url = direct_stream_url(source_id, source_id, token, static: true)



    Map.merge(base, %{
      "SupportsDirectPlay" => true,
      "SupportsDirectStream" => true,
      "SupportsTranscoding" => false,
      "DirectStreamUrl" => url,
      "TranscodingUrl" => nil,
      "TranscodingSubProtocol" => nil,
      "TranscodingContainer" => nil,
      "IsRemote" => false
    })
  end

  defp put_play_method(base, :direct_stream, item_id, source_id, token, session, meta) do
    # Progressive fragmented MP4 remux — playable in HTML5 video elements.
    container = Map.get(meta, :remux_container, "mp4")
    url = remux_url(item_id, source_id, token, session, container)

    Map.merge(base, %{
      "SupportsDirectPlay" => false,
      "SupportsDirectStream" => true,
      "SupportsTranscoding" => true,
      "DirectStreamUrl" => nil,
      "TranscodingUrl" => url,
      "TranscodingSubProtocol" => "http",
      "TranscodingContainer" => container,
      "IsRemote" => false
    })
  end

  defp put_play_method(base, :transcode, item_id, source_id, token, session, _meta) do
    # Progressive fragmented MP4 (H.264/AAC) over HTTP — not multi-segment HLS.
    url = transcode_url(item_id, source_id, token, session)

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

  defp direct_stream_url(path_id, source_id, token, opts) do
    static = if Keyword.get(opts, :static, true), do: "true", else: "false"
    path_id = Id.format(path_id)
    source_id = Id.format(source_id)

    "/Videos/#{path_id}/stream?MediaSourceId=#{encode(source_id)}&Static=#{static}&api_key=#{encode(token)}"
  end

  defp remux_url(item_id, source_id, token, session, container) do
    item_id = Id.format(item_id)
    source_id = Id.format(source_id)

    "/Videos/#{item_id}/stream.#{container}?MediaSourceId=#{encode(source_id)}&PlaySessionId=#{encode(session)}&api_key=#{encode(token)}&Static=false"
  end

  defp transcode_url(item_id, source_id, token, session) do
    item_id = Id.format(item_id)
    source_id = Id.format(source_id)

    "/Videos/#{item_id}/stream.mp4?MediaSourceId=#{encode(source_id)}&PlaySessionId=#{encode(session)}&api_key=#{encode(token)}&Static=false&Transcode=true"
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
