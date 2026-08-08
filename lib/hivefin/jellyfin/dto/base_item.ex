defmodule Hivefin.Jellyfin.Dto.BaseItem do
  @moduledoc """
  Maps domain libraries and items to Jellyfin BaseItemDto-shaped JSON maps.

  Absolute filesystem paths are never included in responses.
  """

  alias Hivefin.Jellyfin.Dto.SdkRequired
  alias Hivefin.Jellyfin.Dto.UserData, as: UserDataDto
  alias Hivefin.Jellyfin.Id
  alias Hivefin.Jellyfin.SystemInfo
  alias Hivefin.Library.{Item, Library, MediaSource, MediaStream, Person, UserData}
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

    sources =
      if playable? or include_field?(fields, "MediaSources"),
        do: load_sources(item, opts),
        else: []

    image_tags = ImageCache.image_tags_for(item)

    base = %{
      "Name" => item.name,
      # Undashed ids — jellyfin-vue route validateGuard requires /[0-9a-f]{32}/
      "Id" => Id.format(item.id),
      "ServerId" => Id.format(SystemInfo.server_id()),
      "Type" => type_name(item.type),
      "MediaType" => media_type(item.type),
      "IsFolder" => folder?(item.type),
      # jellyfin-web skips items without Full play access
      "PlayAccess" => if(playable?, do: "Full", else: "None"),
      "LocationType" => "FileSystem",
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
    |> maybe_put_people(fields, item)
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
  Builds a BaseItemDto map for a `Person` (`/Persons` listing and lookup).

  `Id` and `Type` are the only fields jellyfin-sdk-kotlin's generated
  `BaseItemDto` has no default for — miss either and `MissingFieldException`
  makes the client silently discard the whole object. Everything else here
  (`Name`, `ServerId`, `IsFolder`, `PlayAccess`, `LocationType`, `SortName`,
  `ProviderIds`, `ImageTags`, `PrimaryImageTag`, `UserData`) is technically
  optional per the SDK but emitted anyway, unconditionally, for the same
  reason `from_item/2` always emits them for every other item type:
  jellyfin-web's generic card/list rendering dereferences these without a
  null guard regardless of `Type` — the same trap that produced the
  PlayState/AdditionalUsers crashes referenced in `person_entry/1` below.  A
  Person is not a second, thinner BaseItemDto contract some renderer trips
  over.

  Fields that genuinely don't apply to a person — not playable, not part of
  the item tree — are simply absent (nil, dropped by `drop_nils/1`): no
  `MediaSources`/`RunTimeTicks` (not playable; `MediaType` is omitted the
  same way Series/Season already omit it in production — kotlinx.serialization
  defaults `MediaType` to `Unknown` when the key is missing, so this is not a
  new risk), no `ParentId`/`SeriesId`/`SeasonId`/`ProductionYear`/`Overview`
  (no parent, no release metadata).

  `PrimaryImageTag`/`ImageTags` are derived straight from `profile_path` via
  the same `image_tag/1` hash `person_entry/1` uses — never from a per-person
  `images` table query, and never a second hashing implementation.

  ## Options
  - `:counts` — `PeopleContext.credit_counts/1`'s map (`%{movie: 12}`), which
    becomes `MovieCount`/`SeriesCount`/`EpisodeCount`. Omit it on list paths
    (see `count_fields/1`).
  """
  def from_person(%Person{} = person, opts \\ []) do
    image_tags =
      case person.profile_path do
        path when is_binary(path) and path != "" -> %{"Primary" => image_tag(path)}
        _ -> %{}
      end

    %{
      "Name" => person.name,
      "Id" => Id.format(person.id),
      "ServerId" => Id.format(SystemInfo.server_id()),
      "Type" => "Person",
      "IsFolder" => false,
      "PlayAccess" => "None",
      "LocationType" => "FileSystem",
      "SortName" => person.sort_name || default_sort_name(person.name),
      "ProviderIds" => person.provider_ids || %{},
      "ImageTags" => image_tags,
      "PrimaryImageTag" => Map.get(image_tags, "Primary"),
      "UserData" => user_data(nil)
    }
    |> Map.merge(count_fields(Keyword.get(opts, :counts)))
    |> drop_nils()
  end

  # jellyfin-web 10.10.7 builds the whole body of a person page out of these
  # three fields and nothing else: setInitialCollapsibleState routes
  # Type === "Person" to itemsByName.renderItems, which does
  # `if (item.MovieCount) sections.push({name: "Movies", type: "Movie"})`
  # (and the same for SeriesCount/EpisodeCount), then renders one section per
  # entry. With no counts the section list is empty, so loadItems never runs
  # — and loadItems' query builder is the ONLY place in the client that ever
  # sets `PersonIds`. Miss these and both the person page and the /Items
  # PersonIds filter are dead code. Upstream gets them for free because
  # UserLibraryController.GetItem defaults DtoOptions to AllItemFields, which
  # includes ItemCounts — the same reason ItemsController.show/2 force-appends
  # "People".
  #
  # Zero is emitted as 0, not omitted: `if (0)` is falsy so the section is
  # correctly skipped either way, and a present-but-zero count matches
  # upstream's ItemCounts, which always emits the key.
  #
  # Absent `:counts` emits nothing at all — list paths (`/Persons`, up to 100
  # DTOs a request) must not pay a grouped count per row, and no client reads
  # counts off a person card.
  defp count_fields(nil), do: %{}

  defp count_fields(counts) when is_map(counts) do
    %{
      "MovieCount" => Map.get(counts, :movie, 0),
      "SeriesCount" => Map.get(counts, :series, 0),
      "EpisodeCount" => Map.get(counts, :episode, 0)
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

  # Gated on the Fields check ALONE — deliberately unlike maybe_put_media_sources/4,
  # which also fires for any playable item. Copying that here would attach a full
  # cast list to every movie in a library listing.
  defp maybe_put_people(dto, fields, item) do
    if include_field?(fields, "People") do
      Map.put(dto, "People", people_for(item))
    else
      dto
    end
  end

  # Mirrors ImageCache.image_tags_for/1: consume a batch-preloaded
  # association when the caller (list_items_for_parent/2 et al) already
  # loaded it, so a page of N items costs a fixed 2 queries total instead of
  # 2N. LibraryContext.item_preloads/1 preloads via
  # PeopleContext.ordered_item_people_query/0 — the *same* query
  # list_for_item/1 uses below — so cast-before-crew ordering survives the
  # preload path too.
  defp people_for(%Item{item_people: item_people}) when is_list(item_people) do
    Enum.map(item_people, &person_entry/1)
  end

  # Detail-page callers (get_item/1, get_item_with_sources/1) don't preload
  # item_people — fall back to the single-item query for those.
  defp people_for(%Item{id: id}) when is_binary(id) do
    id
    |> Hivefin.Library.PeopleContext.list_for_item()
    |> Enum.map(&person_entry/1)
  end

  defp people_for(_), do: []

  # Works for both the preloaded %ItemPerson{person: %Person{}} struct and
  # the %{person: %Person{}, ...} map list_for_item/1 returns — same field
  # access either way.
  defp person_entry(entry) do
    # All four emitted unconditionally. Only Id is required by
    # jellyfin-sdk-kotlin, but jellyfin-web dereferences optional fields with
    # no guard — the same trap that produced the PlayState and AdditionalUsers
    # crashes.
    base = %{
      "Id" => Id.format(entry.person.id),
      "Name" => entry.person.name,
      "Role" => entry.role || "",
      "Type" => entry.type
    }

    # PrimaryImageTag is derived from profile_path itself (already loaded on
    # the preloaded Person — zero extra queries), NOT from whether an image
    # is actually cached yet: headshots are fetched lazily by
    # ImagesController on first request, so gating the tag on a cached Image
    # row would mean the client never asks for the photo in the first place.
    # A hash keeps the tag stable across requests and lets it change if TMDb
    # ever swaps the photo. Omitted, never null, when there's no profile_path.
    case entry.person.profile_path do
      path when is_binary(path) and path != "" ->
        Map.put(base, "PrimaryImageTag", image_tag(path))

      _ ->
        base
    end
  end

  defp image_tag(path) do
    :crypto.hash(:md5, path) |> Base.encode16(case: :lower)
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

    # Jellyfin sets primary MediaSource.Id == Item.Id. jellyfin-web and the
    # Android shell then resolve play via getItem(mediaSource.Id); a distinct
    # source UUID 404s and surfaces "Unable to find a valid media source".
    item_id = Id.format(source.item_id)

    %{
      "Id" => item_id,
      "ItemId" => item_id,
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
      "RequiredHttpHeaders" => %{},
      "MediaStreams" => Enum.map(streams, &from_media_stream/1)
    }
    |> SdkRequired.source()
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
    |> SdkRequired.stream()
  end

  # Labels for client track pickers (matches Jellyfin-ish DisplayTitle shape).
  defp display_title(%MediaStream{type: :video} = stream, _layout) do
    res =
      cond do
        is_integer(stream.height) and stream.height > 0 ->
          "#{stream.height}p"

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
