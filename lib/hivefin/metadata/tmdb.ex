defmodule Hivefin.Metadata.TMDB do
  @moduledoc """
  TMDB API client using Req.

  API key is passed as an explicit query param and is never logged.
  """

  @behaviour Hivefin.Metadata.Provider

  require Logger

  alias Hivefin.Metadata.{ProviderCache, RateLimiter}

  @provider "tmdb"

  @impl true
  def search_movie(query, year \\ nil) when is_binary(query) do
    cache_key = "search_movie:" <> query <> ":" <> to_string(year || "")

    case ProviderCache.get(@provider, cache_key) do
      {:ok, %{"results" => results}} when is_list(results) ->
        {:ok, Enum.map(results, &normalize_search_result/1)}

      _ ->
        with {:ok, body} <- get("/search/movie", query_params(query, year)),
             results when is_list(results) <- Map.get(body, "results", []) do
          _ = ProviderCache.put(@provider, cache_key, %{"results" => results})
          {:ok, Enum.map(results, &normalize_search_result/1)}
        else
          {:error, _} = err -> err
          _ -> {:error, :invalid_response}
        end
    end
  end

  @impl true
  def movie_details(tmdb_id) when is_integer(tmdb_id) do
    cache_key = "movie:#{tmdb_id}"

    case ProviderCache.get(@provider, cache_key) do
      {:ok, payload} when is_map(payload) ->
        {:ok, normalize_details(payload)}

      _ ->
        case get("/movie/#{tmdb_id}", %{}) do
          {:ok, body} ->
            _ = ProviderCache.put(@provider, cache_key, body)
            {:ok, normalize_details(body)}

          {:error, _} = err ->
            err
        end
    end
  end

  @impl true
  def image_url(nil, _size), do: nil
  def image_url("", _size), do: nil

  def image_url(path, size) when is_binary(path) do
    size_seg =
      case size do
        :poster -> "w500"
        :backdrop -> "w1280"
        :original -> "original"
        other when is_binary(other) -> other
        _ -> "w500"
      end

    base =
      Application.get_env(:hivefin, :tmdb_image_base_url, "https://image.tmdb.org/t/p")
      |> String.trim_trailing("/")

    path = if String.starts_with?(path, "/"), do: path, else: "/" <> path
    base <> "/" <> size_seg <> path
  end

  # —— Internal ——

  defp query_params(query, nil), do: %{"query" => query}
  defp query_params(query, year) when is_integer(year), do: %{"query" => query, "year" => year}

  defp get(path, params) do
    case api_key() do
      nil ->
        {:error, :missing_api_key}

      "" ->
        {:error, :missing_api_key}

      key ->
        case RateLimiter.checkout() do
          :ok ->
            do_get(path, Map.put(params, "api_key", key))

          :error ->
            {:error, :rate_limited}
        end
    end
  end

  defp do_get(path, params) do
    url = base_url() <> path
    opts = [url: url, params: params] ++ req_options()

    case Req.get(opts) do
      {:ok, %Req.Response{status: 200, body: body}} when is_map(body) ->
        {:ok, body}

      {:ok, %Req.Response{status: status}} when status in 400..499 ->
        Logger.warning("TMDB client error status=#{status} path=#{path}")
        {:error, {:http_error, status}}

      {:ok, %Req.Response{status: status}} ->
        Logger.warning("TMDB server error status=#{status} path=#{path}")
        {:error, {:http_error, status}}

      {:error, reason} ->
        Logger.warning("TMDB request failed path=#{path} reason=#{inspect_safe(reason)}")
        {:error, reason}
    end
  end

  defp base_url do
    Application.get_env(:hivefin, :tmdb_base_url, "https://api.themoviedb.org/3")
    |> String.trim_trailing("/")
  end

  defp api_key do
    Application.get_env(:hivefin, :tmdb_api_key)
  end

  defp req_options do
    Application.get_env(:hivefin, :metadata_req_options, [])
  end

  @doc false
  def redact_secrets(term) when not is_binary(term) do
    term |> inspect() |> redact_secrets()
  end

  def redact_secrets(text) when is_binary(text) do
    text
    # Query-string forms: api_key=… (stop at & # " ' space)
    |> String.replace(~r/api_key=[^&\s#"'<>]+/i, "api_key=REDACTED")
    # JSON / map-ish: "api_key" => "…" or "api_key":"…"
    |> String.replace(~r/"api_key"\s*(?:=>|:)\s*"[^"]*"/i, "\"api_key\" => \"REDACTED\"")
    # Keyword lists in inspect: api_key: "…"
    |> String.replace(~r/api_key:\s*"[^"]*"/i, "api_key: \"REDACTED\"")
  end

  # Never include raw exception messages that may echo query strings with api_key.
  defp inspect_safe(%Req.TransportError{reason: reason}), do: redact_secrets(reason)
  defp inspect_safe(reason) when is_atom(reason), do: inspect(reason)
  defp inspect_safe(reason), do: redact_secrets(reason)

  defp normalize_search_result(result) when is_map(result) do
    %{
      tmdb_id: result["id"],
      name: result["title"] || result["name"] || "",
      overview: result["overview"],
      production_year: year_from_date(result["release_date"]),
      poster_path: result["poster_path"],
      backdrop_path: result["backdrop_path"],
      premiere_date: parse_date(result["release_date"])
    }
  end

  defp normalize_details(body) when is_map(body) do
    %{
      tmdb_id: body["id"],
      name: body["title"] || body["name"] || "",
      overview: body["overview"],
      production_year: year_from_date(body["release_date"]),
      poster_path: body["poster_path"],
      backdrop_path: body["backdrop_path"],
      premiere_date: parse_date(body["release_date"])
    }
  end

  defp year_from_date(<<y::binary-size(4), "-", _::binary>>) do
    case Integer.parse(y) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp year_from_date(_), do: nil

  defp parse_date(<<_::binary-size(10)>> = date) do
    case Date.from_iso8601(date) do
      {:ok, d} -> d
      _ -> nil
    end
  end

  defp parse_date(_), do: nil
end
