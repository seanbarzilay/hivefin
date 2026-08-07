defmodule Hivefin.Scanner.MovieMatcher do
  @moduledoc """
  Parses movie titles and years from folder / file names.
  """

  alias Hivefin.Scanner.PathRules

  @year_pattern ~r/^(?<title>.+)\s+\((?<year>(?:19|20)\d{2})\)\s*$/u
  @year_suffix ~r/^(?<title>.+)[.\s_\-]+(?<year>(?:19|20)\d{2})$/u

  @doc """
  Parses a movie folder or file stem into `%{name: String.t(), year: integer() | nil}`.

      iex> Hivefin.Scanner.MovieMatcher.parse_name("Big Buck Bunny (2008)")
      %{name: "Big Buck Bunny", year: 2008}
  """
  def parse_name(raw) when is_binary(raw) do
    name =
      raw
      |> Path.basename()
      |> strip_video_extension()
      |> String.trim()

    cond do
      match = Regex.named_captures(@year_pattern, name) ->
        %{name: String.trim(match["title"]), year: String.to_integer(match["year"])}

      match = Regex.named_captures(@year_suffix, name) ->
        %{name: clean_title(match["title"]), year: String.to_integer(match["year"])}

      true ->
        %{name: clean_title(name), year: nil}
    end
  end

  defp strip_video_extension(name) do
    if PathRules.video_file?(name) do
      Path.rootname(name)
    else
      name
    end
  end

  defp clean_title(title) do
    title
    |> String.replace(~r/[._]+/, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end
end
