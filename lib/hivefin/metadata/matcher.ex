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
      {:ok, []} ->
        {:error, :no_match}

      {:ok, results} ->
        case pick_best(results, name, year) do
          nil ->
            {:error, :no_match}

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

  defp pick_best(results, name, year) do
    normalized = normalize_name(name)

    scored =
      results
      |> Enum.filter(fn r -> is_integer(r.tmdb_id) end)
      |> Enum.map(fn r ->
        name_score = if normalize_name(r.name) == normalized, do: 2, else: 0

        year_score =
          cond do
            is_nil(year) -> 0
            r.production_year == year -> 2
            is_integer(r.production_year) and abs(r.production_year - year) <= 1 -> 1
            true -> 0
          end

        {name_score + year_score, r}
      end)
      |> Enum.sort_by(fn {score, _} -> -score end)

    case scored do
      [{score, best} | _] when score > 0 or year == nil -> best
      [{_score, best} | _] -> best
      [] -> nil
    end
  end

  defp normalize_name(name) when is_binary(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, " ")
    |> String.trim()
  end

  defp normalize_name(_), do: ""

  defp provider_module do
    Application.get_env(:hivefin, :metadata_provider, TMDB)
  end
end
