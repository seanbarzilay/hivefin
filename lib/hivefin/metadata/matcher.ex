defmodule Hivefin.Metadata.Matcher do
  @moduledoc """
  Matches library items to external provider records (movies by name/year).
  """

  alias Hivefin.Library.Item
  alias Hivefin.Metadata.TMDB

  @doc """
  Searches the configured provider for a movie matching `item` name and year.

  Returns a normalized match map including `tmdb_id`, `name`, `overview`,
  optional image paths, and `provider_ids`.

  Options:
  - `:provider` — module implementing `Hivefin.Metadata.Provider` (default: config / TMDB)
  """
  @spec match_movie(Item.t() | map(), keyword()) :: {:ok, map()} | {:error, term()}
  def match_movie(item, opts \\ [])

  def match_movie(%Item{} = item, opts) do
    match_movie(
      %{name: item.name, production_year: item.production_year, provider_ids: item.provider_ids},
      opts
    )
  end

  def match_movie(%{name: name} = attrs, opts) when is_binary(name) do
    provider = Keyword.get(opts, :provider) || provider_module()
    year = Map.get(attrs, :production_year)

    provider_ids = Map.get(attrs, :provider_ids) || %{}
    existing_id = provider_ids["Tmdb"] || provider_ids["tmdb"] || provider_ids[:Tmdb]

    cond do
      is_integer(existing_id) ->
        fetch_details(provider, existing_id)

      is_binary(existing_id) ->
        case Integer.parse(existing_id) do
          {id, _} -> fetch_details(provider, id)
          :error -> search_and_pick(provider, name, year)
        end

      true ->
        search_and_pick(provider, name, year)
    end
  end

  def match_movie(_, _), do: {:error, :invalid_item}

  defp search_and_pick(provider, name, year) do
    case provider.search_movie(name, year) do
      # Year-filtered search is often empty when folder year is wrong; retry open.
      {:ok, []} when not is_nil(year) ->
        search_and_pick(provider, name, nil)

      {:ok, []} ->
        {:error, :no_match}

      {:ok, results} ->
        case pick_best(results, name, year) do
          nil ->
            # One more try without year when year-scored results all failed.
            if is_nil(year) do
              {:error, :no_match}
            else
              search_and_pick(provider, name, nil)
            end

          match ->
            # Prefer full details when available; fall back to search hit.
            case fetch_details(provider, match.tmdb_id) do
              {:ok, details} -> {:ok, finalize(details)}
              {:error, _} -> {:ok, finalize(match)}
            end
        end

      {:error, _} = err ->
        err
    end
  end

  defp fetch_details(provider, tmdb_id) do
    case provider.movie_details(tmdb_id) do
      {:ok, details} -> {:ok, finalize(details)}
      {:error, _} = err -> err
    end
  end

  defp finalize(match) do
    id = match.tmdb_id

    Map.merge(match, %{
      provider_ids: %{"Tmdb" => to_string(id)}
    })
  end

  # Minimum score to accept a search hit.
  # Name: exact=3, containment=2, token-overlap≥60%=1
  # Year: exact=2, ±1=1 (wrong year does not subtract — folder years are often off)
  @min_match_score 1

  defp pick_best(results, name, year) do
    normalized = normalize_name(name)

    scored =
      results
      |> Enum.filter(fn r -> is_integer(r.tmdb_id) end)
      |> Enum.map(fn r -> {score_result(r, normalized, year), r} end)
      |> Enum.sort_by(fn {score, _} -> -score end)

    case scored do
      [{score, best} | _] when score >= @min_match_score -> best
      _ -> nil
    end
  end

  defp score_result(r, normalized_name, year) do
    name_score = name_affinity(normalized_name, normalize_name(r.name))

    year_score =
      cond do
        is_nil(year) -> 0
        r.production_year == year -> 2
        is_integer(r.production_year) and abs(r.production_year - year) <= 1 -> 1
        true -> 0
      end

    name_score + year_score
  end

  defp name_affinity("", _), do: 0
  defp name_affinity(_, ""), do: 0

  defp name_affinity(a, b) do
    cond do
      a == b -> 3
      String.contains?(a, b) or String.contains?(b, a) -> 2
      token_jaccard(a, b) >= 0.6 -> 1
      true -> 0
    end
  end

  defp token_jaccard(a, b) do
    ta = a |> String.split() |> MapSet.new()
    tb = b |> String.split() |> MapSet.new()

    inter = MapSet.size(MapSet.intersection(ta, tb))
    union = MapSet.size(MapSet.union(ta, tb))

    if union == 0, do: 0.0, else: inter / union
  end

  defp normalize_name(name) when is_binary(name) do
    name
    |> String.downcase()
    # Drop common scene-release noise so "Movie.Name.2020.1080p" still matches.
    |> String.replace(~r/\b(720p|1080p|2160p|4k|uhd|web-?dl|webrip|bluray|x264|x265|hevc|hdr|dv|proper|repack)\b/u, " ")
    |> String.replace(~r/[^a-z0-9]+/u, " ")
    |> String.trim()
  end

  defp normalize_name(_), do: ""

  defp provider_module do
    Application.get_env(:hivefin, :metadata_provider, TMDB)
  end
end
