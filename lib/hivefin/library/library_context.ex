defmodule Hivefin.Library.LibraryContext do
  @moduledoc """
  Domain context for media libraries, items, and media sources.
  """

  import Ecto.Query

  require Logger

  alias Hivefin.Repo
  alias Hivefin.Library.{Item, Library, MediaSource, MediaStream, ScanJob}
  alias Hivefin.MediaInfo.Prober
  alias Hivefin.Scanner.PathRules

  @doc """
  Creates a library.

  ## Attributes
  - `:name` — display name
  - `:type` — `:movies` or `:tv`
  - `:path` — absolute or expandable root path (must exist as a directory)
  """
  def create_library(attrs) do
    %Library{}
    |> Library.changeset(attrs)
    |> Repo.insert()
  end

  def list_libraries do
    Library
    |> order_by([l], asc: l.name)
    |> Repo.all()
  end

  def get_library(id) do
    Repo.get(Library, id)
  end

  def get_library!(id) do
    Repo.get!(Library, id)
  end

  @doc """
  Lists items in a library.

  Options:
  - `:type` — filter by item type (`:movie`, `:series`, etc.)
  """
  def list_items(library_id, opts \\ []) do
    type = Keyword.get(opts, :type)

    Item
    |> where([i], i.library_id == ^library_id)
    |> maybe_filter_type(type)
    |> order_by([i], asc: i.sort_name, asc: i.name)
    |> Repo.all()
  end

  @doc """
  Lists browseable children for Jellyfin Items queries.

  When `parent_id` is `nil`, returns libraries as virtual root folders
  (unless filters select concrete item types such as movies).

  When `parent_id` is a library id, returns items in that library.
  When `parent_id` is an item id, returns direct children of that item.

  ## Options
  - `:include_item_types` — list of atoms (`:movie`, `:series`, …) or nil
  - `:recursive` — when true with item types, search whole library/tree
  - `:limit` — max rows (nil = no limit); negative values clamped to 0
  - `:start_index` — offset (default 0); negative values clamped to 0
  - `:sort_by` — jellyfin field name(s): SortName (default), Name, IndexNumber,
    ProductionYear, PremiereDate, DateCreated (comma-separated; first supported field wins).
    When omitted and parent is a series or season, defaults to IndexNumber.
  - `:preload_media_sources` — preload sources + streams (default false)

  Returns `{entries, total_count}` where entries are `%Library{}` or `%Item{}`.
  """
  def list_items_for_parent(parent_id, opts \\ []) do
    include_types = normalize_include_types(Keyword.get(opts, :include_item_types))
    recursive? = truthy?(Keyword.get(opts, :recursive, false))
    limit = clamp_non_neg(Keyword.get(opts, :limit))
    start_index = clamp_non_neg(Keyword.get(opts, :start_index, 0)) || 0
    sort_raw = Keyword.get(opts, :sort_by)
    preload_sources? = Keyword.get(opts, :preload_media_sources, false)

    cond do
      is_nil(parent_id) and libraries_as_root?(include_types, recursive?) ->
        sort_by = normalize_sort_by(sort_raw)
        libraries = list_libraries() |> sort_libraries(sort_by)
        total = length(libraries)
        {paginate(libraries, start_index, limit), total}

      is_nil(parent_id) ->
        sort_by = normalize_sort_by(sort_raw)

        query =
          Item
          |> maybe_filter_types(include_types)
          |> apply_item_sort(sort_by)

        page_items(query, start_index, limit, preload_sources?)

      library = get_library(parent_id) ->
        sort_by = normalize_sort_by(sort_raw)

        query =
          Item
          |> where([i], i.library_id == ^library.id)
          |> maybe_scope_parent(recursive?, nil)
          |> maybe_filter_types(include_types)
          |> apply_item_sort(sort_by)

        page_items(query, start_index, limit, preload_sources?)

      item = get_item(parent_id) ->
        sort_by = child_sort_for_parent(item, sort_raw)

        query =
          Item
          |> where([i], i.library_id == ^item.library_id)
          |> maybe_scope_parent(recursive?, item.id)
          |> maybe_filter_types(include_types)
          |> apply_item_sort(sort_by)

        page_items(query, start_index, limit, preload_sources?)

      true ->
        {[], 0}
    end
  end

  def get_item(id) do
    Item
    |> where([i], i.id == ^id)
    |> preload(:parent)
    |> Repo.one()
  end

  @doc """
  Gets an item with media sources and streams preloaded.
  """
  def get_item_with_sources(id) do
    Item
    |> where([i], i.id == ^id)
    |> preload([:parent, media_sources: :media_streams])
    |> Repo.one()
  end

  @doc """
  Lists episodes belonging to a series (via season parents).

  Supports the same pagination/sort options as `list_items_for_parent/2`.
  Returns `{entries, total_count}`.
  """
  def list_episodes_for_series(series, opts \\ [])

  def list_episodes_for_series(%Item{type: :series, id: series_id}, opts) do
    limit = clamp_non_neg(Keyword.get(opts, :limit))
    start_index = clamp_non_neg(Keyword.get(opts, :start_index, 0)) || 0
    sort_raw = Keyword.get(opts, :sort_by)
    sort_by = if blank_sort?(sort_raw), do: :index_number, else: normalize_sort_by(sort_raw)
    preload_sources? = Keyword.get(opts, :preload_media_sources, false)

    season_ids =
      Item
      |> where([i], i.parent_id == ^series_id and i.type == :season)
      |> select([i], i.id)
      |> Repo.all()

    query =
      Item
      |> where([i], i.type == :episode and i.parent_id in ^season_ids)
      |> apply_item_sort(sort_by)

    # Empty IN list is fine in Ecto (returns no rows)
    page_items(query, start_index, limit, preload_sources?)
  end

  def list_episodes_for_series(_, _opts), do: {[], 0}

  def list_media_sources(item_id) do
    MediaSource
    |> where([ms], ms.item_id == ^item_id)
    |> order_by([ms], asc: ms.path)
    |> preload([:media_streams])
    |> Repo.all()
  end

  def get_media_source_by_path(path) do
    path = Path.expand(path)

    MediaSource
    |> where([ms], ms.path == ^path)
    |> preload([:item, :media_streams])
    |> Repo.one()
  end

  def get_media_source(id) do
    MediaSource
    |> where([ms], ms.id == ^id)
    |> preload([:media_streams, item: :library])
    |> Repo.one()
  end

  @doc """
  Resolves a filesystem path for progressive streaming.

  Security:
  - `claims.item_id` must match `item_id`
  - `claims.media_source_id` must belong to that item
  - Resolved path must remain under the item's library root
  - File must exist as a regular file

  Returns `{:ok, path}` or `{:error, :not_found | :forbidden}`.
  """
  def media_path_for_item(item_id, claims) when is_binary(item_id) and is_map(claims) do
    claim_item_id = Map.get(claims, :item_id) || Map.get(claims, "item_id")
    source_id = Map.get(claims, :media_source_id) || Map.get(claims, "media_source_id")

    cond do
      not is_binary(claim_item_id) or not is_binary(source_id) ->
        {:error, :forbidden}

      claim_item_id != item_id ->
        {:error, :forbidden}

      true ->
        resolve_media_path(item_id, source_id)
    end
  end

  def media_path_for_item(_, _), do: {:error, :forbidden}

  defp resolve_media_path(item_id, source_id) do
    case get_media_source(source_id) do
      %MediaSource{item_id: ^item_id, path: path} = source when is_binary(path) ->
        item = loaded_or(source.item, fn -> get_item(item_id) end)

        library =
          case item do
            %Item{} = item ->
              loaded_or(item.library, fn -> get_library(item.library_id) end)

            _ ->
              nil
          end

        cond do
          is_nil(library) ->
            {:error, :not_found}

          not PathRules.under_root?(library.path, path) ->
            {:error, :forbidden}

          not File.regular?(path) ->
            {:error, :not_found}

          true ->
            {:ok, Path.expand(path)}
        end

      %MediaSource{} ->
        {:error, :forbidden}

      nil ->
        {:error, :not_found}
    end
  end

  defp loaded_or(%Ecto.Association.NotLoaded{}, fun), do: fun.()
  defp loaded_or(nil, fun), do: fun.()
  defp loaded_or(value, _fun), do: value

  def create_scan_job(attrs) do
    %ScanJob{}
    |> ScanJob.changeset(attrs)
    |> Repo.insert()
  end

  def update_scan_job(%ScanJob{} = job, attrs) do
    job
    |> ScanJob.changeset(attrs)
    |> Repo.update()
  end

  def get_latest_scan_job(library_id) do
    ScanJob
    |> where([j], j.library_id == ^library_id)
    |> order_by([j], desc: j.inserted_at, desc: j.id)
    |> limit(1)
    |> Repo.one()
  end

  def list_scan_jobs(library_id) do
    ScanJob
    |> where([j], j.library_id == ^library_id)
    |> order_by([j], desc: j.inserted_at)
    |> Repo.all()
  end

  def touch_library_scanned(%Library{} = library, at \\ DateTime.utc_now()) do
    library
    |> Ecto.Changeset.change(last_scanned_at: DateTime.truncate(at, :microsecond))
    |> Repo.update()
  end

  @doc """
  Finds an existing movie item by library + name + year, or creates one.
  """
  def find_or_create_movie(library_id, attrs) do
    name = Map.fetch!(attrs, :name)
    year = Map.get(attrs, :production_year)

    query =
      Item
      |> where([i], i.library_id == ^library_id and i.type == :movie and i.name == ^name)

    query =
      if is_nil(year) do
        where(query, [i], is_nil(i.production_year))
      else
        where(query, [i], i.production_year == ^year)
      end

    case Repo.one(query) do
      %Item{} = item ->
        {:ok, item, :existing}

      nil ->
        case %Item{}
             |> Item.changeset(
               Map.merge(attrs, %{type: :movie, library_id: library_id, parent_id: nil})
             )
             |> Repo.insert() do
          {:ok, item} -> {:ok, item, :created}
          error -> error
        end
    end
  end

  @doc """
  Finds or creates a series (top-level TV item) by library + name.
  """
  def find_or_create_series(library_id, attrs) do
    name = Map.fetch!(attrs, :name)

    query =
      Item
      |> where(
        [i],
        i.library_id == ^library_id and i.type == :series and i.name == ^name and
          is_nil(i.parent_id)
      )

    case Repo.one(query) do
      %Item{} = item ->
        {:ok, item, :existing}

      nil ->
        case %Item{}
             |> Item.changeset(%{
               type: :series,
               library_id: library_id,
               parent_id: nil,
               name: name,
               production_year: Map.get(attrs, :production_year)
             })
             |> Repo.insert() do
          {:ok, item} -> {:ok, item, :created}
          error -> error
        end
    end
  end

  @doc """
  Finds or creates a season under a series by season index (`index_number`).
  """
  def find_or_create_season(library_id, series_id, season_number)
      when is_integer(season_number) do
    query =
      Item
      |> where(
        [i],
        i.library_id == ^library_id and i.type == :season and i.parent_id == ^series_id and
          i.index_number == ^season_number
      )

    case Repo.one(query) do
      %Item{} = item ->
        {:ok, item, :existing}

      nil ->
        case %Item{}
             |> Item.changeset(%{
               type: :season,
               library_id: library_id,
               parent_id: series_id,
               name: "Season #{season_number}",
               index_number: season_number
             })
             |> Repo.insert() do
          {:ok, item} -> {:ok, item, :created}
          error -> error
        end
    end
  end

  @doc """
  Finds or creates an episode under a season by episode index (`index_number`).
  """
  def find_or_create_episode(library_id, season_id, attrs) do
    index = Map.fetch!(attrs, :index_number)
    name = Map.get(attrs, :name) || "Episode #{index}"

    query =
      Item
      |> where(
        [i],
        i.library_id == ^library_id and i.type == :episode and i.parent_id == ^season_id and
          i.index_number == ^index
      )

    case Repo.one(query) do
      %Item{} = item ->
        {:ok, item, :existing}

      nil ->
        case %Item{}
             |> Item.changeset(%{
               type: :episode,
               library_id: library_id,
               parent_id: season_id,
               name: name,
               index_number: index,
               parent_index_number: Map.get(attrs, :parent_index_number)
             })
             |> Repo.insert() do
          {:ok, item} -> {:ok, item, :created}
          error -> error
        end
    end
  end

  @doc """
  Upserts a media source for an item.

  Probes with ffprobe only on create or when size/mtime changed.
  On re-probe failure, updates file metadata but **keeps** existing streams.
  """
  def upsert_media_source(item_id, path, file_stat) do
    path = Path.expand(path)
    container = path |> Path.extname() |> String.trim_leading(".") |> String.downcase()
    mtime = unix_mtime_to_datetime(file_stat.mtime)
    size = file_stat.size

    case get_media_source_by_path(path) do
      %MediaSource{} = existing ->
        if unchanged?(existing, size, mtime) do
          {:ok, existing, :unchanged}
        else
          update_changed_source(existing, item_id, path, container, size, mtime)
        end

      nil ->
        create_source_with_probe(item_id, path, container, size, mtime)
    end
  end

  defp unchanged?(%MediaSource{} = existing, size, mtime) do
    existing.size == size and equal_mtime?(existing.mtime, mtime)
  end

  defp create_source_with_probe(item_id, path, container, size, mtime) do
    probe_result =
      case Prober.probe(path) do
        {:ok, result} ->
          result

        {:error, reason} ->
          Logger.warning("ffprobe failed for new source #{path}: #{inspect(reason)}")
          %{format: %{}, streams: []}
      end

    attrs = source_attrs(item_id, path, container, size, mtime, probe_result)

    Repo.transaction(fn ->
      source =
        %MediaSource{}
        |> MediaSource.changeset(attrs)
        |> Repo.insert!()

      insert_streams!(source.id, probe_result)
      Repo.preload(source, :media_streams)
    end)
    |> case do
      {:ok, source} -> {:ok, source, :created}
      {:error, reason} -> {:error, reason}
    end
  end

  defp update_changed_source(existing, item_id, path, container, size, mtime) do
    case Prober.probe(path) do
      {:ok, probe_result} ->
        replace_streams_and_update(existing, item_id, path, container, size, mtime, probe_result)

      {:error, reason} ->
        Logger.warning(
          "ffprobe failed for changed source #{path}; keeping existing streams: #{inspect(reason)}"
        )

        update_metadata_keep_streams(existing, item_id, path, container, size, mtime)
    end
  end

  defp replace_streams_and_update(existing, item_id, path, container, size, mtime, probe_result) do
    attrs = source_attrs(item_id, path, container, size, mtime, probe_result)

    Repo.transaction(fn ->
      from(s in MediaStream, where: s.media_source_id == ^existing.id)
      |> Repo.delete_all()

      source =
        existing
        |> MediaSource.changeset(attrs)
        |> Repo.update!()

      insert_streams!(source.id, probe_result)
      Repo.preload(source, :media_streams, force: true)
    end)
    |> case do
      {:ok, source} -> {:ok, source, :updated}
      {:error, reason} -> {:error, reason}
    end
  end

  defp update_metadata_keep_streams(existing, item_id, path, container, size, mtime) do
    attrs = %{
      item_id: item_id,
      path: path,
      container: container,
      size: size,
      mtime: mtime
    }

    existing
    |> MediaSource.changeset(attrs)
    |> Repo.update()
    |> case do
      {:ok, source} ->
        {:ok, Repo.preload(source, :media_streams, force: true), :updated}

      error ->
        error
    end
  end

  defp source_attrs(item_id, path, container, size, mtime, probe_result) do
    %{
      item_id: item_id,
      path: path,
      container: container,
      size: size,
      mtime: mtime,
      bitrate: get_in(probe_result, [:format, :bit_rate]),
      duration_ticks: duration_ticks(probe_result)
    }
  end

  defp insert_streams!(media_source_id, %{streams: streams}) when is_list(streams) do
    Enum.each(streams, fn stream_attrs ->
      %MediaStream{}
      |> MediaStream.changeset(Map.put(stream_attrs, :media_source_id, media_source_id))
      |> Repo.insert!()
    end)
  end

  defp insert_streams!(_media_source_id, _), do: :ok

  defp duration_ticks(%{format: %{duration: duration}}) when is_number(duration) do
    trunc(duration * 10_000_000)
  end

  defp duration_ticks(_), do: nil

  defp unix_mtime_to_datetime({{y, m, d}, {hh, mm, ss}}) do
    {:ok, naive} = NaiveDateTime.new(y, m, d, hh, mm, ss)
    DateTime.from_naive!(naive, "Etc/UTC")
  end

  defp unix_mtime_to_datetime(unix) when is_integer(unix) do
    DateTime.from_unix!(unix) |> DateTime.truncate(:microsecond)
  end

  defp equal_mtime?(%DateTime{} = a, %DateTime{} = b) do
    DateTime.compare(DateTime.truncate(a, :second), DateTime.truncate(b, :second)) == :eq
  end

  defp equal_mtime?(_, _), do: false

  defp maybe_filter_type(query, nil), do: query
  defp maybe_filter_type(query, type), do: where(query, [i], i.type == ^type)

  defp maybe_filter_types(query, nil), do: query
  defp maybe_filter_types(query, []), do: query
  defp maybe_filter_types(query, types), do: where(query, [i], i.type in ^types)

  defp apply_item_sort(query, :index_number) do
    order_by(query, [i], asc_nulls_last: i.index_number, asc: i.sort_name, asc: i.name)
  end

  defp apply_item_sort(query, :production_year) do
    order_by(query, [i], asc_nulls_last: i.production_year, asc: i.sort_name, asc: i.name)
  end

  defp apply_item_sort(query, :premiere_date) do
    order_by(query, [i], asc_nulls_last: i.premiere_date, asc: i.sort_name, asc: i.name)
  end

  defp apply_item_sort(query, :date_created) do
    order_by(query, [i], asc: i.inserted_at, asc: i.sort_name, asc: i.name)
  end

  defp apply_item_sort(query, :name) do
    order_by(query, [i], asc: i.name, asc: i.sort_name)
  end

  defp apply_item_sort(query, _sort_name) do
    order_by(query, [i], asc: i.sort_name, asc: i.name)
  end

  # Seasons under series / episodes under season default to numeric IndexNumber.
  defp child_sort_for_parent(%Item{type: type}, sort_raw)
       when type in [:series, :season] and sort_raw in [nil, ""] do
    :index_number
  end

  defp child_sort_for_parent(_parent, sort_raw), do: normalize_sort_by(sort_raw)

  defp blank_sort?(nil), do: true
  defp blank_sort?(""), do: true
  defp blank_sort?(_), do: false

  defp sort_libraries(libraries, :name) do
    Enum.sort_by(libraries, & &1.name)
  end

  defp sort_libraries(libraries, :date_created) do
    Enum.sort_by(libraries, & &1.inserted_at, DateTime)
  end

  defp sort_libraries(libraries, _) do
    Enum.sort_by(libraries, &String.downcase(&1.name || ""))
  end

  defp normalize_sort_by(nil), do: :sort_name
  defp normalize_sort_by(""), do: :sort_name

  defp normalize_sort_by(sort_by) when is_binary(sort_by) do
    sort_by
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.find_value(:sort_name, &sort_field_atom/1)
  end

  defp normalize_sort_by(sort_by) when is_list(sort_by) do
    Enum.find_value(sort_by, :sort_name, fn
      field when is_binary(field) -> sort_field_atom(field)
      field when is_atom(field) -> sort_field_atom(Atom.to_string(field))
      _ -> nil
    end) || :sort_name
  end

  defp normalize_sort_by(sort_by) when is_atom(sort_by) do
    sort_field_atom(Atom.to_string(sort_by)) || :sort_name
  end

  defp normalize_sort_by(_), do: :sort_name

  defp sort_field_atom(field) when is_binary(field) do
    case field |> String.trim() |> String.downcase() do
      "sortname" -> :sort_name
      "name" -> :name
      "indexnumber" -> :index_number
      "productionyear" -> :production_year
      "premieredate" -> :premiere_date
      "datecreated" -> :date_created
      _ -> nil
    end
  end

  defp clamp_non_neg(nil), do: nil
  defp clamp_non_neg(n) when is_integer(n) and n < 0, do: 0
  defp clamp_non_neg(n) when is_integer(n), do: n
  defp clamp_non_neg(_), do: nil

  # Root with no concrete type filter → libraries as CollectionFolders.
  # When client asks for Movie/Series/etc (esp. recursive), query items instead.
  defp libraries_as_root?(nil, _recursive?), do: true
  defp libraries_as_root?([], _recursive?), do: true
  defp libraries_as_root?(_types, true), do: false
  defp libraries_as_root?(_types, false), do: false

  defp maybe_scope_parent(query, true, _parent_id), do: query

  defp maybe_scope_parent(query, false, nil) do
    where(query, [i], is_nil(i.parent_id))
  end

  defp maybe_scope_parent(query, false, parent_id) do
    where(query, [i], i.parent_id == ^parent_id)
  end

  defp page_items(query, start_index, limit, preload_sources?) do
    total = Repo.aggregate(query, :count, :id)
    preloads = item_preloads(preload_sources?)

    query =
      query
      |> offset(^start_index)
      |> maybe_limit(limit)
      # Parent association needed for Episode SeriesId (season.parent_id).
      |> preload(^preloads)

    {Repo.all(query), total}
  end

  defp maybe_limit(query, nil), do: query
  defp maybe_limit(query, limit) when is_integer(limit) and limit >= 0, do: limit(query, ^limit)
  defp maybe_limit(query, _), do: query

  defp item_preloads(true), do: [:parent, media_sources: :media_streams]
  defp item_preloads(_), do: [:parent]

  defp paginate(list, start_index, nil) when start_index <= 0, do: list

  defp paginate(list, start_index, nil) do
    Enum.drop(list, start_index)
  end

  defp paginate(list, start_index, limit) when is_integer(limit) do
    list
    |> Enum.drop(max(start_index, 0))
    |> Enum.take(limit)
  end

  defp normalize_include_types(nil), do: nil
  defp normalize_include_types([]), do: nil

  defp normalize_include_types(types) when is_list(types) do
    types
    |> Enum.map(&normalize_item_type/1)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      list -> list
    end
  end

  defp normalize_include_types(type), do: normalize_include_types([type])

  defp normalize_item_type(type) when type in [:movie, :series, :season, :episode], do: type

  defp normalize_item_type(type) when is_binary(type) do
    case String.downcase(type) do
      "movie" -> :movie
      "series" -> :series
      "season" -> :season
      "episode" -> :episode
      _ -> nil
    end
  end

  defp normalize_item_type(_), do: nil

  defp truthy?(v) when v in [true, "true", "True", "1", 1], do: true
  defp truthy?(_), do: false
end
