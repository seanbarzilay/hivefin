defmodule Hivefin.Library.LibraryContext do
  @moduledoc """
  Domain context for media libraries, items, and media sources.
  """

  import Ecto.Query

  require Logger

  alias Hivefin.Repo
  alias Hivefin.Library.{Item, Library, MediaSource, MediaStream, ScanJob}
  alias Hivefin.MediaInfo.Prober

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

  def get_item(id) do
    Repo.get(Item, id)
  end

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
end
