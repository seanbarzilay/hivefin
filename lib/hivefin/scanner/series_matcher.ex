defmodule Hivefin.Scanner.SeriesMatcher do
  @moduledoc """
  Parses season/episode markers from TV filenames and season folder names.
  """

  # S01E02, s1e2, S01.E02, S01_E02
  @season_episode ~r/(?<![A-Za-z0-9])[Ss](?<season>\d{1,2})[.\s_\-]*[Ee](?<episode>\d{1,3})(?![A-Za-z0-9])/

  @season_folder ~r/^(?:Season|Seasons|Saison)\s*(?<season>\d{1,2})$/iu

  @video_exts ~w(.mp4 .mkv .avi .m4v .ts .m2ts .webm)

  @doc """
  Parses a TV episode filename into `%{season: integer(), episode: integer()}` or `nil`.

      iex> Hivefin.Scanner.SeriesMatcher.parse_filename("Foo S01E02.mkv")
      %{season: 1, episode: 2}
  """
  def parse_filename(raw) when is_binary(raw) do
    name =
      raw
      |> Path.basename()
      |> strip_video_extension()

    case Regex.named_captures(@season_episode, name) do
      %{"season" => season, "episode" => episode} ->
        %{season: String.to_integer(season), episode: String.to_integer(episode)}

      nil ->
        nil
    end
  end

  @doc """
  Parses a season folder name such as `"Season 01"` into a season number, or `nil`.
  """
  def parse_season_folder(name) when is_binary(name) do
    name = String.trim(name)

    case Regex.named_captures(@season_folder, name) do
      %{"season" => season} -> String.to_integer(season)
      nil -> nil
    end
  end

  defp strip_video_extension(name) do
    ext = name |> Path.extname() |> String.downcase()

    if ext in @video_exts do
      Path.rootname(name)
    else
      name
    end
  end
end
