defmodule Hivefin.Scanner do
  @moduledoc """
  Cancellable library scanner.

  Production API is asynchronous (`scan_library/1`); tests may use
  `scan_library_sync/1` which runs the pipeline in the calling process.
  """

  use GenServer

  require Logger

  alias Hivefin.Library.LibraryContext
  alias Hivefin.MediaInfo.Prober
  alias Hivefin.Scanner.{MovieMatcher, PathRules, Walker}

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
  Cancels a running scan for `library_id`. Always returns `:ok`.
  """
  def cancel(library_id, server \\ __MODULE__) do
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

  # —— GenServer ——

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:scan_library, library_id}, _from, state) do
    cond do
      Map.has_key?(state.running, library_id) ->
        {:reply, {:error, :already_scanning}, state}

      is_nil(LibraryContext.get_library(library_id)) ->
        {:reply, {:error, :not_found}, state}

      true ->
        parent = self()
        library = LibraryContext.get_library!(library_id)

        {:ok, job} =
          LibraryContext.create_scan_job(%{
            library_id: library_id,
            status: :running,
            started_at: DateTime.utc_now() |> DateTime.truncate(:microsecond),
            items_found: 0,
            items_added: 0
          })

        task =
          Task.async(fn ->
            result = do_scan_library(library, job, fn -> cancelled?(parent, library_id) end)
            {:scan_done, library_id, result}
          end)

        running = Map.put(state.running, library_id, %{task: task, job: job})
        {:reply, :ok, %{state | running: running}}
    end
  end

  def handle_call({:cancel, library_id}, _from, state) do
    case Map.get(state.running, library_id) do
      nil ->
        {:reply, :ok, state}

      %{task: task, job: job} ->
        Task.shutdown(task, :brutal_kill)

        LibraryContext.update_scan_job(job, %{
          status: :cancelled,
          finished_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
        })

        {:reply, :ok, %{state | running: Map.delete(state.running, library_id)}}
    end
  end

  def handle_call({:cancelled?, library_id}, _from, state) do
    {:reply, not Map.has_key?(state.running, library_id), state}
  end

  @impl true
  def handle_info({ref, {:scan_done, library_id, result}}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    state = finish_running(state, library_id, result)
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    entry =
      Enum.find(state.running, fn {_id, %{task: task}} -> task.ref == ref end)

    state =
      case entry do
        {library_id, %{job: job}} ->
          if reason != :normal do
            LibraryContext.update_scan_job(job, %{
              status: :failed,
              error: inspect(reason),
              finished_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
            })
          end

          %{state | running: Map.delete(state.running, library_id)}

        nil ->
          state
      end

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp finish_running(state, library_id, _result) do
    %{state | running: Map.delete(state.running, library_id)}
  end

  defp cancelled?(parent, library_id) do
    GenServer.call(parent, {:cancelled?, library_id})
  rescue
    _ -> true
  end

  # —— Scan pipeline ——

  defp run_scan(library) do
    {:ok, job} =
      LibraryContext.create_scan_job(%{
        library_id: library.id,
        status: :running,
        started_at: DateTime.utc_now() |> DateTime.truncate(:microsecond),
        items_found: 0,
        items_added: 0
      })

    do_scan_library(library, job, fn -> false end)
  end

  defp do_scan_library(library, job, cancel_fun) do
    if cancel_fun.() do
      finalize_job(job, :cancelled, 0, 0, nil)
      {:error, :cancelled}
    else
      try do
        case library.type do
          :movies ->
            {found, added} = scan_movies(library, cancel_fun)
            finalize_job(job, :completed, found, added, nil)
            LibraryContext.touch_library_scanned(library)
            :ok

          :tv ->
            finalize_job(job, :failed, 0, 0, "TV scanning not implemented yet")
            {:error, :tv_not_implemented}
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
  end

  defp scan_movies(library, cancel_fun) do
    root = library.path

    videos = Walker.list_video_files(root)

    Enum.reduce(videos, {0, 0}, fn path, {found, added} ->
      if cancel_fun.() do
        throw({:cancelled, found, added})
      end

      if PathRules.under_root?(root, path) do
        case import_movie_file(library, root, path) do
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
    {:cancelled, found, added} -> {found, added}
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
         probe <- probe_or_empty(path),
         {:ok, _source, source_status} <-
           LibraryContext.upsert_media_source(item.id, path, stat, probe) do
      status =
        cond do
          item_status == :created or source_status == :created -> :created
          source_status == :updated -> :updated
          true -> :unchanged
        end

      {:ok, status}
    else
      {:error, reason} -> {:error, reason}
      false -> {:error, :outside_root}
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

  defp probe_or_empty(path) do
    case Prober.probe(path) do
      {:ok, result} ->
        result

      {:error, reason} ->
        Logger.warning("ffprobe failed for #{path}: #{inspect(reason)}")
        %{format: %{}, streams: []}
    end
  end

  defp finalize_job(job, status, found, added, error) do
    LibraryContext.update_scan_job(job, %{
      status: status,
      items_found: found,
      items_added: added,
      error: error,
      finished_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
    })
  end
end
