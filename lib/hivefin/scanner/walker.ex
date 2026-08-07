defmodule Hivefin.Scanner.Walker do
  @moduledoc """
  Recursive directory walker for media libraries.

  Walks **all subdirectories** under the library root (Jellyfin-style
  `Movies/Title (Year)/file.mkv` and `TV/Show/Season 01/…` layouts).
  """

  require Logger

  alias Hivefin.Scanner.PathRules

  @doc """
  Walks `root` and returns video file paths under it.

  ## Return values
  - `{:ok, paths}` — walk finished (list may be empty)
  - `{:error, :not_a_directory}` — root missing or not a directory
  - `{:error, :eacces}` — permission denied reading the root (common in Docker if
    the media mount is not readable by the container user)
  - `{:error, reason}` — other `File.ls/1` error on the root
  """
  def list_video_files(root) when is_binary(root) do
    root = Path.expand(root)

    cond do
      not File.exists?(root) ->
        Logger.error("scan root does not exist: #{root}")
        {:error, :enoent}

      not File.dir?(root) ->
        Logger.error("scan root is not a directory: #{root}")
        {:error, :not_a_directory}

      true ->
        case File.ls(root) do
          {:ok, _} ->
            files = do_walk(root, root, [])
            Logger.info("scan walk #{root}: #{length(files)} video file(s)")
            {:ok, files}

          {:error, reason} ->
            Logger.error("scan root not readable #{root}: #{inspect(reason)}")
            {:error, reason}
        end
    end
  end

  defp do_walk(root, dir, acc) do
    case File.ls(dir) do
      {:ok, entries} ->
        Enum.reduce(entries, acc, fn name, acc ->
          if PathRules.ignored_name?(name) do
            acc
          else
            path = Path.join(dir, name)

            cond do
              # Recursive: every non-ignored subdirectory is walked
              File.dir?(path) ->
                do_walk(root, path, acc)

              PathRules.video_file?(path) ->
                if PathRules.under_root?(root, path) do
                  [path | acc]
                else
                  Logger.warning("skip video outside library root after resolve: #{path}")
                  acc
                end

              true ->
                acc
            end
          end
        end)

      {:error, reason} ->
        Logger.warning("cannot list #{dir}: #{inspect(reason)}")
        acc
    end
  end
end
