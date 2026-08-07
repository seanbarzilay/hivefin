defmodule Hivefin.Scanner do
  @moduledoc """
  Cancellable library scanner.

  Production API is asynchronous (`scan_library/1`); tests may use
  `scan_library_sync/1` which runs the pipeline in the calling process.

  Cancel is cooperative via an ETS flag (workers never `GenServer.call` the
  scanner). Hard cancel also terminates the scan task. Orphaned `:running`
  scan jobs are marked `:failed` on scanner init (e.g. after crash/restart).
  """

  use GenServer

  require Logger

  import Ecto.Query

  alias Hivefin.Library.{LibraryContext, ScanJob}
  alias Hivefin.Metadata.Worker, as: MetadataWorker
  alias Hivefin.Repo
  alias Hivefin.Scanner.{MovieMatcher, PathRules, SeriesMatcher, Walker}

  @cancel_table :hivefin_scanner_cancel
  @task_supervisor Hivefin.Scanner.TaskSupervisor

  defstruct running: %{}

  # —— Public API ——

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, %__MODULE__{}, name: name)
  end

  @doc """
  Starts an async full scan for `library_id`.

  Returns `:ok` if accepted, or `{:error, reason}` if the library is missing
  or a scan is already running for that library.
  """
  def scan_library(library_id, server \\ __MODULE__) do
    GenServer.call(server, {:scan_library, library_id})
  end

  @doc """
  Starts scans for every library that is not already scanning.

  Returns `%{started: [id], skipped: [{id, reason}], errors: [{id, reason}]}`.
  """
  def scan_all(server \\ __MODULE__) do
    libraries = LibraryContext.list_libraries()

    Enum.reduce(libraries, %{started: [], skipped: [], errors: []}, fn lib, acc ->
      case scan_library(lib.id, server) do
        :ok ->
          %{acc | started: [lib.id | acc.started]}

        {:error, :already_scanning} ->
          %{acc | skipped: [{lib.id, :already_scanning} | acc.skipped]}

        {:error, reason} ->
          %{acc | errors: [{lib.id, reason} | acc.errors]}
      end
    end)
    |> then(fn acc ->
      %{
        started: Enum.reverse(acc.started),
        skipped: Enum.reverse(acc.skipped),
        errors: Enum.reverse(acc.errors)
      }
    end)
  end

  @doc """
  Library ids currently being scanned by this scanner process.
  """
  def running_ids(server \\ __MODULE__) do
    GenServer.call(server, :running_ids)
  end

  @doc """
  Cancels a running scan for `library_id`. Always returns `:ok`.
  """
  def cancel(library_id, server \\ __MODULE__) do
    library_id = Hivefin.Jellyfin.Id.coerce(library_id) || library_id
    GenServer.call(server, {:cancel, library_id})
  end

  @doc """
  Runs a full scan synchronously in the calling process (test helper).
  """
  def scan_library_sync(library_id) do
    case LibraryContext.get_library(library_id) do
      nil ->
        {:error, :not_found}

      library ->
        run_scan(library)
    end
  end

  @doc false
  def cancelled?(library_id) do
    case :ets.lookup(@cancel_table, library_id) do
      [{^library_id, true}] -> true
      _ -> false
    end
  end

  # —— GenServer ——

  @impl true
  def init(state) do
    ensure_cancel_table!()
    fail_orphaned_scan_jobs()
    {:ok, state}
  end

  @impl true
  def handle_call(:running_ids, _from, state) do
    {:reply, Map.keys(state.running), state}
  end

  def handle_call({:scan_library, library_id}, _from, state) do
    library_id = Hivefin.Jellyfin.Id.coerce(library_id) || library_id

    cond do
      Map.has_key?(state.running, library_id) ->
        {:reply, {:error, :already_scanning}, state}

      is_nil(LibraryContext.get_library(library_id)) ->
        {:reply, {:error, :not_found}, state}

      true ->
        library = LibraryContext.get_library!(library_id)
        clear_cancel_flag(library_id)

        {:ok, job} =
          LibraryContext.create_scan_job(%{
            library_id: library_id,
            status: :running,
            started_at: now(),
            items_found: 0,
            items_added: 0
          })

        task =
          Task.Supervisor.async_nolink(@task_supervisor, fn ->
            allow_repo_sandbox()
            result = do_scan_library(library, job, fn -> cancelled?(library_id) end)
            {:scan_done, library_id, job.id, result}
          end)

        running = Map.put(state.running, library_id, %{task: task, job: job})
        {:reply, :ok, %{state | running: running}}
    end
  end

  def handle_call({:cancel, library_id}, _from, state) do
    case Map.pop(state.running, library_id) do
      {nil, _} ->
        {:reply, :ok, state}

      {%{task: task, job: job}, running} ->
        set_cancel_flag(library_id)
        _ = Task.shutdown(task, :brutal_kill)
        mark_job_cancelled_if_running(job)
        clear_cancel_flag(library_id)
        {:reply, :ok, %{state | running: running}}
    end
  end

  @impl true
  def handle_info({ref, {:scan_done, library_id, _job_id, _result}}, state)
      when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    clear_cancel_flag(library_id)
    {:noreply, %{state | running: Map.delete(state.running, library_id)}}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    entry =
      Enum.find(state.running, fn {_id, %{task: %Task{ref: task_ref}}} -> task_ref == ref end)

    state =
      case entry do
        {library_id, %{job: job}} ->
          if reason not in [:normal, :noproc] do
            mark_job_failed_if_running(job, inspect(reason))
          end

          clear_cancel_flag(library_id)
          %{state | running: Map.delete(state.running, library_id)}

        nil ->
          state
      end

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # —— Scan pipeline ——

  defp run_scan(library) do
    clear_cancel_flag(library.id)

    {:ok, job} =
      LibraryContext.create_scan_job(%{
        library_id: library.id,
        status: :running,
        started_at: now(),
        items_found: 0,
        items_added: 0
      })

    do_scan_library(library, job, fn -> cancelled?(library.id) end)
  end

  defp do_scan_library(library, job, cancel_fun) do
    start = System.monotonic_time()

    result =
      if cancel_fun.() do
        finalize_job(job, :cancelled, 0, 0, nil)
        {:error, :cancelled}
      else
        try do
          maybe_test_delay()

          case library.type do
            :movies ->
              case scan_movies(library, cancel_fun) do
                {:cancelled, found, added} ->
                  finalize_job(job, :cancelled, found, added, nil)
                  {:error, :cancelled}

                {found, added} ->
                  if cancel_fun.() do
                    finalize_job(job, :cancelled, found, added, nil)
                    {:error, :cancelled}
                  else
                    finalize_job(job, :completed, found, added, nil)
                    LibraryContext.touch_library_scanned(library)
                    {:ok, found, added}
                  end
              end

            :tv ->
              case scan_tv(library, cancel_fun) do
                {:cancelled, found, added} ->
                  finalize_job(job, :cancelled, found, added, nil)
                  {:error, :cancelled}

                {found, added} ->
                  if cancel_fun.() do
                    finalize_job(job, :cancelled, found, added, nil)
                    {:error, :cancelled}
                  else
                    finalize_job(job, :completed, found, added, nil)
                    LibraryContext.touch_library_scanned(library)
                    {:ok, found, added}
                  end
              end
          end
        rescue
          e ->
            Logger.error("scan failed for library #{library.id}: #{Exception.message(e)}")
            finalize_job(job, :failed, 0, 0, Exception.message(e))
            {:error, e}
        catch
          :exit, reason ->
            finalize_job(job, :failed, 0, 0, inspect(reason))
            {:error, reason}
        end
      end

    emit_scan_stop(library, job, start, result)

    case result do
      {:ok, _found, _added} -> :ok
      other -> other
    end
  end

  defp emit_scan_stop(library, job, start, result) do
    duration = System.monotonic_time() - start

    {status, found, added} =
      case result do
        {:ok, found, added} -> {:completed, found, added}
        {:error, :cancelled} -> {:cancelled, 0, 0}
        {:error, _} -> {:failed, 0, 0}
      end

    :telemetry.execute(
      [:hivefin, :scan, :stop],
      %{duration: duration},
      %{
        library_id: library.id,
        library_type: library.type,
        job_id: job.id,
        status: status,
        items_found: found,
        items_added: added
      }
    )
  end

  defp scan_movies(library, cancel_fun) do
    scan_video_files(library, cancel_fun, &import_movie_file/3)
  end

  defp scan_tv(library, cancel_fun) do
    scan_video_files(library, cancel_fun, &import_tv_file/3)
  end

  defp scan_video_files(library, cancel_fun, import_fun) do
    root = library.path
    videos = Walker.list_video_files(root)

    Enum.reduce(videos, {0, 0}, fn path, {found, added} ->
      maybe_test_hook(library.id)
      maybe_test_delay()

      if cancel_fun.() do
        throw({:cancelled, found, added})
      end

      if PathRules.under_root?(root, path) do
        case import_fun.(library, root, path) do
          {:ok, :created} ->
            {found + 1, added + 1}

          {:ok, _} ->
            {found + 1, added}

          {:error, reason} ->
            Logger.warning("skip #{path}: #{inspect(reason)}")
            {found, added}
        end
      else
        Logger.warning("reject path outside library root: #{path}")
        {found, added}
      end
    end)
  catch
    {:cancelled, found, added} -> {:cancelled, found, added}
  end

  defp import_movie_file(library, root, path) do
    with {:ok, stat} <- File.stat(path),
         true <- PathRules.under_root?(root, path) || {:error, :outside_root},
         parsed <- movie_identity(root, path),
         {:ok, item, item_status} <-
           LibraryContext.find_or_create_movie(library.id, %{
             name: parsed.name,
             production_year: parsed.year
           }),
         # Probe only inside upsert when size/mtime require it
         {:ok, _source, source_status} <-
           LibraryContext.upsert_media_source(item.id, path, stat) do
      maybe_enqueue_metadata(item, item_status)
      {:ok, import_status(item_status, source_status)}
    else
      {:error, reason} -> {:error, reason}
      false -> {:error, :outside_root}
    end
  end

  # Best-effort: never fail the scan if metadata enqueue/refresh errors.
  defp maybe_enqueue_metadata(%{type: :movie, id: id}, :created) when is_binary(id) do
    MetadataWorker.enqueue_refresh(id)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp maybe_enqueue_metadata(_item, _status), do: :ok

  defp import_tv_file(library, root, path) do
    with {:ok, stat} <- File.stat(path),
         true <- PathRules.under_root?(root, path) || {:error, :outside_root},
         {:ok, identity} <- tv_identity(root, path),
         {:ok, series, series_status} <-
           LibraryContext.find_or_create_series(library.id, %{name: identity.series_name}),
         {:ok, season, season_status} <-
           LibraryContext.find_or_create_season(library.id, series.id, identity.season),
         {:ok, episode, episode_status} <-
           LibraryContext.find_or_create_episode(library.id, season.id, %{
             name: identity.episode_name,
             index_number: identity.episode,
             parent_index_number: identity.season
           }),
         {:ok, _source, source_status} <-
           LibraryContext.upsert_media_source(episode.id, path, stat) do
      item_status =
        if series_status == :created or season_status == :created or episode_status == :created do
          :created
        else
          :existing
        end

      {:ok, import_status(item_status, source_status)}
    else
      {:error, reason} -> {:error, reason}
      false -> {:error, :outside_root}
    end
  end

  defp import_status(item_status, source_status) do
    cond do
      item_status == :created or source_status == :created -> :created
      source_status == :updated -> :updated
      true -> :unchanged
    end
  end

  defp movie_identity(root, path) do
    parent = Path.dirname(path)
    root = Path.expand(root)

    label =
      if parent != root and PathRules.under_root?(root, parent) do
        Path.basename(parent)
      else
        path |> Path.basename() |> Path.rootname()
      end

    MovieMatcher.parse_name(label)
  end

  # Layouts:
  # 1. Series Name/Season 01/Series Name S01E02.mkv
  # 2. Series Name/Series Name S01E02.mkv  (season from filename)
  defp tv_identity(root, path) do
    root = Path.expand(root)
    path = Path.expand(path)
    rel = Path.relative_to(path, root)
    parts = Path.split(rel)
    filename = List.last(parts)

    case SeriesMatcher.parse_filename(filename) do
      %{episode: episode} = ep ->
        with {:ok, series_name} <- series_name_from_parts(parts, filename),
             {:ok, season} <- resolve_season(parts, ep) do
          {:ok,
           %{
             series_name: series_name,
             season: season,
             episode: episode,
             episode_name: "Episode #{episode}"
           }}
        end

      nil ->
        {:error, :unrecognized_episode_filename}
    end
  end

  defp series_name_from_parts([series | rest], _filename) when rest != [] do
    name =
      series |> String.replace(~r/[._]+/, " ") |> String.replace(~r/\s+/, " ") |> String.trim()

    if name == "" do
      {:error, :missing_series_name}
    else
      {:ok, name}
    end
  end

  defp series_name_from_parts(_parts, _filename), do: {:error, :missing_series_folder}

  defp resolve_season(parts, %{season: season_from_file}) do
    case parts do
      [_series, season_folder, _file] ->
        case SeriesMatcher.parse_season_folder(season_folder) do
          n when is_integer(n) -> {:ok, n}
          nil -> {:ok, season_from_file}
        end

      [_series, _file] ->
        {:ok, season_from_file}

      _ ->
        {:ok, season_from_file}
    end
  end

  defp finalize_job(job, status, found, added, error) do
    # Avoid clobbering a terminal status set by cancel/DOWN races.
    case Repo.get(ScanJob, job.id) do
      %ScanJob{status: :running} = current ->
        LibraryContext.update_scan_job(current, %{
          status: status,
          items_found: found,
          items_added: added,
          error: error,
          finished_at: now()
        })

      _ ->
        :ok
    end
  end

  defp mark_job_cancelled_if_running(job) do
    case Repo.get(ScanJob, job.id) do
      %ScanJob{status: :running} = current ->
        LibraryContext.update_scan_job(current, %{
          status: :cancelled,
          finished_at: now()
        })

      _ ->
        :ok
    end
  end

  defp mark_job_failed_if_running(job, error) do
    case Repo.get(ScanJob, job.id) do
      %ScanJob{status: :running} = current ->
        LibraryContext.update_scan_job(current, %{
          status: :failed,
          error: error,
          finished_at: now()
        })

      _ ->
        :ok
    end
  end

  defp fail_orphaned_scan_jobs do
    now = now()

    {count, _} =
      from(j in ScanJob, where: j.status == :running)
      |> Repo.update_all(
        set: [
          status: "failed",
          error: "scanner restarted with job still running",
          finished_at: now
        ]
      )

    if count > 0 do
      Logger.warning("marked #{count} orphaned scan job(s) as failed")
    end
  rescue
    e ->
      Logger.warning("could not fail orphaned scan jobs: #{Exception.message(e)}")
  end

  defp ensure_cancel_table! do
    case :ets.whereis(@cancel_table) do
      :undefined ->
        :ets.new(@cancel_table, [
          :named_table,
          :public,
          :set,
          read_concurrency: true,
          write_concurrency: true
        ])

      _tid ->
        @cancel_table
    end
  end

  defp set_cancel_flag(library_id), do: :ets.insert(@cancel_table, {library_id, true})
  defp clear_cancel_flag(library_id), do: :ets.delete(@cancel_table, library_id)

  defp allow_repo_sandbox do
    case Application.get_env(:hivefin, :scanner_repo_owner) do
      owner when is_pid(owner) ->
        Ecto.Adapters.SQL.Sandbox.allow(Repo, owner, self())

      _ ->
        :ok
    end
  end

  defp maybe_test_delay do
    case Application.get_env(:hivefin, :scanner_test_delay_ms) do
      ms when is_integer(ms) and ms > 0 -> Process.sleep(ms)
      _ -> :ok
    end
  end

  defp maybe_test_hook(library_id) do
    case Application.get_env(:hivefin, :scanner_test_hook) do
      fun when is_function(fun, 1) -> fun.(library_id)
      _ -> :ok
    end
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
