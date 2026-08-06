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

  Follows symlinks via `realpath/1` so a link planted under the library that
  points outside the root is rejected.
  """
  def under_root?(root, path) when is_binary(root) and is_binary(path) do
    with {:ok, root_real} <- realpath(root),
         {:ok, path_real} <- realpath(path) do
      root_real = String.trim_trailing(root_real, "/")
      path_real == root_real or String.starts_with?(path_real, root_real <> "/")
    else
      _ -> false
    end
  end

  @doc """
  Canonical absolute path with symlinks resolved.

  Returns `{:ok, path}` or `{:error, reason}` (`:enoent`, `:symlink_loop`, …).
  Non-existent leaf paths still resolve parent components so callers can reason
  about logical placement; missing roots yield `{:error, :enoent}`.
  """
  @spec realpath(String.t()) :: {:ok, String.t()} | {:error, atom()}
  def realpath(path) when is_binary(path) do
    resolve_symlinks(Path.expand(path), MapSet.new())
  end

  defp resolve_symlinks(path, seen) do
    if MapSet.member?(seen, path) do
      {:error, :symlink_loop}
    else
      seen = MapSet.put(seen, path)

      case File.read_link(path) do
        {:ok, target} ->
          next =
            if Path.type(target) == :absolute do
              Path.expand(target)
            else
              Path.expand(target, Path.dirname(path))
            end

          resolve_symlinks(next, seen)

        {:error, :einval} ->
          # Not a symlink — resolve parents so intermediate links are followed.
          parent = Path.dirname(path)

          if parent == path do
            {:ok, path}
          else
            case resolve_symlinks(parent, seen) do
              {:ok, real_parent} ->
                candidate = Path.join(real_parent, Path.basename(path))

                if candidate == path do
                  {:ok, path}
                else
                  resolve_symlinks(candidate, seen)
                end

              error ->
                error
            end
          end

        {:error, :enoent} ->
          parent = Path.dirname(path)

          if parent == path do
            {:error, :enoent}
          else
            case resolve_symlinks(parent, seen) do
              {:ok, real_parent} ->
                {:ok, Path.join(real_parent, Path.basename(path))}

              error ->
                error
            end
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
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
