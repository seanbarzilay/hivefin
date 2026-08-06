defmodule Hivefin.Scanner.PathRules do
  @moduledoc """
  Path safety and media file classification rules for library scanning.
  """

  @video_extensions MapSet.new(~w(.mp4 .mkv .avi .m4v .ts .m2ts .webm))

  @ignored_dirs MapSet.new([
                  "@eadir",
                  "extras",
                  "samples",
                  "sample",
                  "trailer",
                  "trailers",
                  "featurettes",
                  "behind the scenes"
                ])

  @doc """
  Returns true when `path` resolves under (or equals) `root`.
  Protects against path traversal outside library roots.
  """
  def under_root?(root, path) when is_binary(root) and is_binary(path) do
    root = Path.expand(root)
    path = Path.expand(path)
    String.starts_with?(path, root <> "/") or path == root
  end

  def video_file?(path) when is_binary(path) do
    ext = path |> Path.extname() |> String.downcase()
    MapSet.member?(@video_extensions, ext)
  end

  def video_extensions, do: MapSet.to_list(@video_extensions)

  @doc """
  Whether a directory or file basename should be skipped during walks.
  Ignores: `@eaDir`, `.DS_Store`, dotfiles/dirs, `extras`, `samples` (case-insensitive).
  """
  def ignored_name?(name) when is_binary(name) do
    cond do
      name in [".", ".."] -> true
      String.starts_with?(name, ".") -> true
      String.downcase(name) == "@eadir" -> true
      MapSet.member?(@ignored_dirs, String.downcase(name)) -> true
      true -> false
    end
  end
end
