defmodule Hivefin.Jellyfin.Dto.BaseItem do
  @moduledoc """
  Maps domain libraries and items to Jellyfin BaseItemDto-shaped JSON maps.

  Absolute filesystem paths are never included in responses.
  """

  alias Hivefin.Jellyfin.SystemInfo
  alias Hivefin.Library.{Item, Library, MediaSource, MediaStream}

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

    base = %{
      "Name" => item.name,
      "Id" => item.id,
      "ServerId" => SystemInfo.server_id(),
      "Type" => type_name(item.type),
      "IsFolder" => folder?(item.type),
      "SortName" => item.sort_name || default_sort_name(item.name),
      "ProductionYear" => item.production_year,
      "PremiereDate" => premiere_date(item.premiere_date),
      "Overview" => item.overview,
      "IndexNumber" => item.index_number,
      "ParentIndexNumber" => item.parent_index_number,
      "ParentId" => item.parent_id,
      "ProviderIds" => item.provider_ids || %{},
      "ImageTags" => %{},
      "UserData" => user_data(user_data)
    }

    base
    |> maybe_put_media_sources(item, fields, opts)
    |> drop_nils()
  end

  @doc """
  Builds a BaseItemDto map for a library root (CollectionFolder / UserView).
  """
  def from_library(%Library{} = library, opts \\ []) do
    type = Keyword.get(opts, :type, "CollectionFolder")

    %{
      "Name" => library.name,
      "Id" => library.id,
      "ServerId" => SystemInfo.server_id(),
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

  defp maybe_put_media_sources(dto, item, fields, opts) do
    if include_field?(fields, "MediaSources") do
      sources =
        Keyword.get(opts, :media_sources) ||
          Map.get(item, :media_sources) ||
          []

      sources =
        case sources do
          %Ecto.Association.NotLoaded{} -> []
          list when is_list(list) -> list
          _ -> []
        end

      Map.put(dto, "MediaSources", Enum.map(sources, &from_media_source/1))
    else
      dto
    end
  end

  defp from_media_source(%MediaSource{} = source) do
    streams =
      case Map.get(source, :media_streams) do
        %Ecto.Association.NotLoaded{} -> []
        list when is_list(list) -> list
        _ -> []
      end

    %{
      "Id" => source.id,
      "Container" => source.container,
      "Size" => source.size,
      "Bitrate" => source.bitrate,
      "RunTimeTicks" => source.duration_ticks,
      "Type" => "Default",
      "Protocol" => "File",
      "SupportsDirectPlay" => true,
      "SupportsDirectStream" => true,
      "SupportsTranscoding" => false,
      "MediaStreams" => Enum.map(streams, &from_media_stream/1)
    }
    |> drop_nils()
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

  defp type_name(:movie), do: "Movie"
  defp type_name(:series), do: "Series"
  defp type_name(:season), do: "Season"
  defp type_name(:episode), do: "Episode"
  defp type_name(other) when is_atom(other), do: other |> Atom.to_string() |> Macro.camelize()

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

  defp user_data(nil), do: default_user_data()
  defp user_data(%{} = data), do: Map.merge(default_user_data(), stringify_keys(data))

  defp default_user_data do
    %{
      "PlaybackPositionTicks" => 0,
      "PlayCount" => 0,
      "IsFavorite" => false,
      "Played" => false,
      "PlayedPercentage" => 0
    }
  end

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

  defp stringify_keys(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k) |> Macro.camelize(), v}
      {k, v} when is_binary(k) -> {k, v}
    end)
  end

  defp drop_nils(map) do
    map
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end
end
