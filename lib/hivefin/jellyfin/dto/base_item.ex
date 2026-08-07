defmodule Hivefin.Jellyfin.Dto.BaseItem do
  @moduledoc """
  Maps domain libraries and items to Jellyfin BaseItemDto-shaped JSON maps.

  Absolute filesystem paths are never included in responses.
  """

  alias Hivefin.Jellyfin.Dto.UserData, as: UserDataDto
  alias Hivefin.Jellyfin.Id
  alias Hivefin.Jellyfin.SystemInfo
  alias Hivefin.Library.{Item, Library, MediaSource, MediaStream, UserData}
  alias Hivefin.Metadata.ImageCache


  @type field_opt :: String.t() | atom()

  @doc """
  Builds a BaseItemDto map for a media `Item`.

  ## Options
  - `:user_data` — map or `nil` (defaults applied)
  - `:fields` — list of extra fields (e.g. `["MediaSources"]` or `[:media_sources]`)
  - `:media_sources` — preloaded sources if not on the item association
  """
  def from_item(%Item{} = item, opts \\ []) do
    fields = normalize_fields(Keyword.get(opts, :fields, []))
    user_data = Keyword.get(opts, :user_data)
    playable? = item.type in [:movie, :episode]
    sources = if playable? or include_field?(fields, "MediaSources"), do: load_sources(item, opts), else: []
    image_tags = ImageCache.image_tags_for(item)

    base = %{
      "Name" => item.name,
      # Undashed ids — jellyfin-vue route validateGuard requires /[0-9a-f]{32}/
      "Id" => Id.format(item.id),
      "ServerId" => Id.format(SystemInfo.server_id()),
      "Type" => type_name(item.type),
      "MediaType" => media_type(item.type),
      "IsFolder" => folder?(item.type),
      "SortName" => item.sort_name || default_sort_name(item.name),
      "ProductionYear" => item.production_year,
      "PremiereDate" => premiere_date(item.premiere_date),
      "Overview" => item.overview,
      "IndexNumber" => item.index_number,
      "ParentIndexNumber" => item.parent_index_number,
      # Movies/root items use library id as ParentId so clients nest under the view.
      "ParentId" => Id.format(item.parent_id || item.library_id),
      "SeriesId" => Id.format(series_id(item)),
      "SeasonId" => Id.format(season_id(item)),
      "ProviderIds" => item.provider_ids || %{},
      "ImageTags" => image_tags,
      # Some clients (and person cards) prefer PrimaryImageTag over ImageTags.
      "PrimaryImageTag" => Map.get(image_tags, "Primary"),
      "UserData" => user_data(user_data),
      "RunTimeTicks" => runtime_ticks_from_sources(sources)
    }

    base
    |> maybe_put_media_sources(playable?, fields, sources)
    |> drop_nils()
  end



  @doc """
  Builds a BaseItemDto map for a library root (CollectionFolder / UserView).
  """
  def from_library(%Library{} = library, opts \\ []) do
    type = Keyword.get(opts, :type, "CollectionFolder")

    %{
      "Name" => library.name,
      "Id" => Id.format(library.id),
      "ServerId" => Id.format(SystemInfo.server_id()),
      "Type" => type,
      "CollectionType" => collection_type(library.type),
      "IsFolder" => true,
      "SortName" => default_sort_name(library.name),
      "ImageTags" => %{},
      "UserData" => user_data(Keyword.get(opts, :user_data))
    }
  end


  @doc """
  Query result wrapper used by Items list endpoints.
  """
  def query_result(items, total_count) when is_list(items) and is_integer(total_count) do
    %{
      "Items" => items,
      "TotalRecordCount" => total_count,
      "StartIndex" => 0
    }
  end

  def query_result(items, total_count, start_index)
      when is_list(items) and is_integer(total_count) and is_integer(start_index) do
    %{
      "Items" => items,
      "TotalRecordCount" => total_count,
      "StartIndex" => start_index
    }
  end

  defp maybe_put_media_sources(dto, playable?, fields, sources) do
    if playable? or include_field?(fields, "MediaSources") do
      Map.put(dto, "MediaSources", Enum.map(sources, &from_media_source/1))
    else
      dto
    end
  end

  defp load_sources(item, opts) do
    sources =
      Keyword.get(opts, :media_sources) ||
        Map.get(item, :media_sources) ||
        []

    case sources do
      # Controllers must preload media_sources for playable items (avoid Repo in DTO).
      %Ecto.Association.NotLoaded{} ->
        []

      list when is_list(list) ->
        list

      _ ->
        []
    end
  end


  defp runtime_ticks_from_sources([%MediaSource{duration_ticks: ticks} | _])
       when is_integer(ticks) and ticks > 0,
       do: ticks

  defp runtime_ticks_from_sources(_), do: nil


  defp from_media_source(%MediaSource{} = source) do
    streams =
      case Map.get(source, :media_streams) do
        %Ecto.Association.NotLoaded{} -> []
        list when is_list(list) -> list
        _ -> []
      end

    # jellyfin-vue selects the *player* (native <video> vs hls.js) from
    # Item.MediaSources.SupportsDirectPlay — NOT PlaybackInfo. If this is
    # always true, vue assigns master.m3u8 to video.src and Chrome never
    # runs hls.js (no segments, "nothing plays"). Only mark DirectPlay for
    # formats browsers can actually decode without MSE/HLS.
    browser_dp? = browser_direct_play_safe?(source, streams)

    %{
      "Id" => Id.format(source.id),
      # ItemId helps clients that key streams by item
      "ItemId" => Id.format(source.item_id),
      "Container" => source.container || "mp4",
      "Size" => source.size,
      "Bitrate" => source.bitrate,
      "RunTimeTicks" => source.duration_ticks,
      "Type" => "Default",
      # Http so browsers fetch via progressive stream URL
      "Protocol" => "Http",
      "SupportsDirectPlay" => browser_dp?,
      "SupportsDirectStream" => browser_dp?,
      "SupportsTranscoding" => true,
      "MediaStreams" => Enum.map(streams, &from_media_stream/1)
    }
    |> drop_nils()
  end

  # Progressive DirectPlay in Chrome/Firefox/Safari <video> without hls.js.
  # MKV/HEVC/HDR still DirectPlay via PlaybackInfo for native apps; Item flags
  # only gate the vue player element choice.
  defp browser_direct_play_safe?(%MediaSource{} = source, streams) when is_list(streams) do
    container = source.container |> to_string() |> String.downcase()
    video = first_stream_codec(streams, :video)
    audio = first_stream_codec(streams, :audio)

    container in ~w(mp4 m4v webm mov) and
      video in [nil, "h264", "avc1", "avc", "vp8", "vp9", "av1"] and
      audio in [nil, "aac", "mp3", "opus", "vorbis", "flac"]
  end

  defp first_stream_codec(streams, type) do
    streams
    |> Enum.find(fn s -> Map.get(s, :type) == type end)
    |> case do
      nil -> nil
      s -> s.codec && String.downcase(s.codec)
    end
  end



  defp from_media_stream(%MediaStream{} = stream) do
    channel_layout = channel_layout(stream.channels)

    %{
      "Index" => stream.index,
      "Type" => stream_type_name(stream.type),
      "Codec" => stream.codec,
      "Language" => stream.language,
      "Channels" => stream.channels,
      "ChannelLayout" => channel_layout,
      "Width" => stream.width,
      "Height" => stream.height,
      "BitRate" => stream.bit_rate,
      "IsDefault" => stream.is_default || false,
      "IsForced" => stream.is_forced || false,
      "Title" => stream.title,
      # jellyfin-vue MediaStreamSelector labels only use DisplayTitle
      "DisplayTitle" => display_title(stream, channel_layout)
    }
    |> drop_nils()
  end

  # Labels for client track pickers (matches Jellyfin-ish DisplayTitle shape).
  defp display_title(%MediaStream{type: :video} = stream, _layout) do
    res =
      cond do
        is_integer(stream.height) and stream.height > 0 -> "#{stream.height}p"
        is_integer(stream.width) and is_integer(stream.height) ->
          "#{stream.width}x#{stream.height}"

        true ->
          nil
      end

    codec = codec_label(stream.codec)
    join_title_parts([res, codec, default_suffix(stream)])
  end

  defp display_title(%MediaStream{type: :audio} = stream, layout) do
    join_title_parts([
      language_label(stream.language),
      codec_label(stream.codec),
      audio_layout_label(stream.channels, layout),
      default_suffix(stream)
    ])
  end

  defp display_title(%MediaStream{type: :subtitle} = stream, _layout) do
    join_title_parts([
      language_label(stream.language),
      codec_label(stream.codec),
      forced_suffix(stream),
      default_suffix(stream)
    ])
  end

  defp display_title(%MediaStream{} = stream, _layout) do
    join_title_parts([codec_label(stream.codec), stream.title])
  end

  defp join_title_parts(parts) do
    parts
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.join(" ")
    |> case do
      "" -> "Unknown"
      title -> title
    end
  end

  defp codec_label(nil), do: nil
  defp codec_label(""), do: nil

  defp codec_label(codec) when is_binary(codec) do
    codec
    |> String.trim()
    |> String.upcase()
  end

  defp codec_label(_), do: nil

  defp language_label(nil), do: nil
  defp language_label(""), do: nil
  defp language_label(lang) when lang in ["und", "unk", "unknown"], do: nil

  defp language_label(lang) when is_binary(lang) do
    case String.downcase(lang) do
      "en" -> "English"
      "eng" -> "English"
      "es" -> "Spanish"
      "spa" -> "Spanish"
      "fr" -> "French"
      "fre" -> "French"
      "fra" -> "French"
      "de" -> "German"
      "ger" -> "German"
      "deu" -> "German"
      "ja" -> "Japanese"
      "jpn" -> "Japanese"
      "zh" -> "Chinese"
      "chi" -> "Chinese"
      "zho" -> "Chinese"
      "ko" -> "Korean"
      "kor" -> "Korean"
      "pt" -> "Portuguese"
      "por" -> "Portuguese"
      "it" -> "Italian"
      "ita" -> "Italian"
      "ru" -> "Russian"
      "rus" -> "Russian"
      other -> String.upcase(other)
    end
  end

  defp language_label(_), do: nil

  defp channel_layout(1), do: "1.0"
  defp channel_layout(2), do: "2.0"
  defp channel_layout(6), do: "5.1"
  defp channel_layout(8), do: "7.1"
  defp channel_layout(n) when is_integer(n) and n > 0, do: to_string(n)
  defp channel_layout(_), do: nil

  defp audio_layout_label(2, "2.0"), do: "Stereo"
  defp audio_layout_label(_channels, layout) when is_binary(layout), do: layout
  defp audio_layout_label(n, _) when is_integer(n) and n > 0, do: "#{n} ch"
  defp audio_layout_label(_, _), do: nil

  defp default_suffix(%MediaStream{is_default: true}), do: "- Default"
  defp default_suffix(_), do: nil

  defp forced_suffix(%MediaStream{is_forced: true}), do: "Forced"
  defp forced_suffix(_), do: nil

  defp type_name(:movie), do: "Movie"
  defp type_name(:series), do: "Series"
  defp type_name(:season), do: "Season"
  defp type_name(:episode), do: "Episode"
  defp type_name(other) when is_atom(other), do: other |> Atom.to_string() |> Macro.camelize()

  # jellyfin-vue keys off MediaType === "Video" for the local player
  defp media_type(:movie), do: "Video"
  defp media_type(:episode), do: "Video"
  defp media_type(_), do: nil


  defp stream_type_name(:video), do: "Video"
  defp stream_type_name(:audio), do: "Audio"
  defp stream_type_name(:subtitle), do: "Subtitle"

  defp stream_type_name(other) when is_atom(other),
    do: other |> Atom.to_string() |> Macro.camelize()

  defp collection_type(:movies), do: "movies"
  defp collection_type(:tv), do: "tvshows"
  defp collection_type(_), do: "unknown"

  defp folder?(:movie), do: false
  defp folder?(:episode), do: false
  defp folder?(:series), do: true
  defp folder?(:season), do: true
  defp folder?(_), do: false

  # Season parent is the series; episode's series is season.parent_id when parent preloaded.
  defp series_id(%Item{type: :season, parent_id: parent_id}), do: parent_id

  defp series_id(%Item{type: :episode, parent: %Item{parent_id: series_id}}), do: series_id

  defp series_id(%Item{type: :episode, parent: %Ecto.Association.NotLoaded{}}), do: nil
  defp series_id(_), do: nil

  defp season_id(%Item{type: :episode, parent_id: parent_id}), do: parent_id
  defp season_id(_), do: nil

  defp user_data(nil), do: UserDataDto.default()
  defp user_data(%UserData{} = data), do: UserDataDto.from_user_data(data)
  defp user_data(%{} = data), do: UserDataDto.from_user_data(data)

  defp premiere_date(%Date{} = date), do: Date.to_iso8601(date)
  defp premiere_date(_), do: nil

  defp default_sort_name(name) when is_binary(name), do: String.downcase(name)
  defp default_sort_name(_), do: ""

  defp normalize_fields(fields) when is_list(fields) do
    Enum.map(fields, fn
      f when is_atom(f) -> f |> Atom.to_string() |> Macro.camelize()
      f when is_binary(f) -> f
    end)
  end

  defp normalize_fields(_), do: []

  defp include_field?(fields, name), do: name in fields

  defp drop_nils(map) do
    map
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end
end
