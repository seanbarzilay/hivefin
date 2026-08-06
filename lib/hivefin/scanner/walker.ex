defmodule Hivefin.Scanner.Walker do
  @moduledoc """
  Recursive directory walker for media libraries.
  """

  alias Hivefin.Scanner.PathRules

  @doc """
  Walks `root` and returns a list of absolute video file paths under it.
  Skips ignored directory/file names and non-video files.
  """
  def list_video_files(root) when is_binary(root) do
    root = Path.expand(root)

    if File.dir?(root) do
      do_walk(root, root, [])
    else
      []
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
              File.dir?(path) ->
                do_walk(root, path, acc)

              PathRules.video_file?(path) and PathRules.under_root?(root, path) ->
                [path | acc]

              true ->
                acc
            end
          end
        end)

      {:error, _} ->
        acc
    end
  end
end
