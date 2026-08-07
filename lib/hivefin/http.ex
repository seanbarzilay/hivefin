defmodule Hivefin.Http do
  @moduledoc """
  HTTP helpers for outbound fetches (TMDB API + artwork CDN).

  Prefer Req; on OTP TLS failures fall back to `curl` (reliable in Debian
  containers where Erlang/OTP SSL rejects some intermediate certs).
  """

  require Logger

  @doc """
  GET `url` and return the response body as a binary.

  Options:
  - `:params` — query params (merged into URL for curl)
  - `:req_options` — extra Req options (e.g. test plugs)
  - `:decode_json` — when true (default false), JSON-decode map bodies via Req
  """
  def get_body(url, opts \\ []) when is_binary(url) do
    params = Keyword.get(opts, :params, %{})
    req_opts = Keyword.get(opts, :req_options, [])
    decode_json? = Keyword.get(opts, :decode_json, false)

    case get_with_req(url, params, req_opts, decode_json?) do
      {:ok, _} = ok ->
        ok

      {:error, reason} = err ->
        if tls_error?(reason) and curl_available?() do
          Logger.debug("Req TLS failed, retrying with curl: #{inspect_safe(reason)}")
          get_with_curl(url, params, decode_json?)
        else
          err
        end
    end
  end

  defp get_with_req(url, params, req_opts, decode_json?) do
    opts =
      [url: url, params: params, decode_body: decode_json?]
      |> Keyword.merge(req_opts)

    case Req.get(opts) do
      {:ok, %Req.Response{status: 200, body: body, headers: headers}} ->
        cond do
          decode_json? and is_map(body) ->
            {:ok, %{status: 200, body: body, headers: headers}}

          is_binary(body) and byte_size(body) > 0 ->
            {:ok, %{status: 200, body: body, headers: headers}}

          decode_json? ->
            {:error, :invalid_response}

          true ->
            {:error, :empty_body}
        end

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp get_with_curl(url, params, decode_json?) do
    full_url = append_params(url, params)
    tmp = Path.join(System.tmp_dir!(), "hivefin-http-#{System.unique_integer([:positive])}")

    try do
      {out, code} =
        System.cmd(
          "curl",
          ["-fsSL", "--max-time", "60", "-o", tmp, "-w", "%{http_code}", full_url],
          stderr_to_stdout: true
        )

      case Integer.parse(String.trim(out)) do
        {200, _} when code == 0 ->
          case File.read(tmp) do
            {:ok, body} when byte_size(body) > 0 ->
              if decode_json? do
                case Jason.decode(body) do
                  {:ok, map} when is_map(map) ->
                    {:ok, %{status: 200, body: map, headers: []}}

                  _ ->
                    {:error, :invalid_response}
                end
              else
                {:ok, %{status: 200, body: body, headers: []}}
              end

            {:ok, _} ->
              {:error, :empty_body}

            {:error, reason} ->
              {:error, reason}
          end

        {status, _} ->
          {:error, {:http_error, status}}

        :error ->
          {:error, {:curl_failed, code, out}}
      end
    after
      _ = File.rm(tmp)
    end
  end

  defp append_params(url, params) when params == %{}, do: url

  defp append_params(url, params) when is_map(params) do
    q =
      params
      |> Enum.map(fn {k, v} ->
        URI.encode_www_form(to_string(k)) <> "=" <> URI.encode_www_form(to_string(v))
      end)
      |> Enum.join("&")

    if String.contains?(url, "?"), do: url <> "&" <> q, else: url <> "?" <> q
  end

  defp tls_error?(%Req.TransportError{reason: {:tls_alert, _}}), do: true
  defp tls_error?({:tls_alert, _}), do: true
  defp tls_error?(%{reason: {:tls_alert, _}}), do: true

  defp tls_error?(reason) when is_binary(reason),
    do: String.contains?(reason, "tls_alert") or String.contains?(reason, "Unsupported Certificate")

  defp tls_error?(reason), do: reason |> inspect() |> tls_error?()

  defp curl_available? do
    case System.find_executable("curl") do
      path when is_binary(path) -> true
      _ -> false
    end
  end

  defp inspect_safe(term) do
    term
    |> inspect()
    |> String.replace(~r/api_key=[^&\s#"']+/i, "api_key=REDACTED")
  end
end
