defmodule HivefinWeb.WebClientController do
  @moduledoc """
  Serves the bundled Jellyfin web UI (SPA fallback to index.html).

  Official Jellyfin Android/TV apps are WebViews that `loadUrl(serverRoot)` and
  expect `main.*.bundle.js` from jellyfin-web. Without this, connect fails
  even when `/System/Info/Public` works.
  """
  use HivefinWeb, :controller

  # Never SPA-fallback these — they must 404 as JSON if unrouted, not HTML.
  # `web` is deliberately absent: in Jellyfin /web IS the web client, not an API
  # root. Blacklisting it made /web/* return JSON 404, so the LG webOS app failed
  # at its /web/manifest.json probe. Real files under /web are served by
  # Plug.Static; everything else falls through here for SPA routing.
  @api_roots ~w(
    system users items videos sessions branding shows userviews useritems
    displaypreferences healthz readyz quickconnect admin api socket liveStreams
    livestreams libraries artists genres persons studios playbackinfo
    startup localization configuration playback
  )

  @doc """
  Serves `priv/jellyfin-web/index.html` for SPA client-side routes.
  """
  def index(conn, params) do
    path_info = Map.get(params, "path") || []

    cond do
      api_like?(path_info) ->
        conn
        |> put_status(:not_found)
        |> json(%{"error" => "not_found"})

      # Missing webpack chunks must 404 — not index.html (breaks dynamic import).
      static_asset?(path_info) ->
        conn
        |> put_status(:not_found)
        |> put_resp_content_type("text/plain")
        |> send_resp(404, "not found")

      true ->
        serve_index(conn)
    end
  end

  defp serve_index(conn) do
    path = index_path()

    if is_binary(path) and File.regular?(path) do
      conn
      |> put_resp_content_type("text/html")
      |> put_resp_header("cache-control", "no-cache")
      |> send_file(200, path)
    else
      conn
      |> put_status(:service_unavailable)
      |> put_resp_content_type("text/plain")
      |> send_resp(
        503,
        "Jellyfin web UI is not bundled in this build (priv/jellyfin-web missing)."
      )
    end
  end

  defp api_like?([]), do: false

  defp api_like?([first | _]) when is_binary(first) do
    String.downcase(first) in @api_roots
  end

  defp api_like?(_), do: false

  defp static_asset?([]), do: false

  defp static_asset?(path_info) when is_list(path_info) do
    last = List.last(path_info) || ""

    String.contains?(last, ".") and
      String.downcase(Path.extname(last)) in ~w(
        .js .css .map .json .woff .woff2 .ttf .eot .svg .png .jpg .jpeg .gif
        .webp .ico .wasm .txt .xml
      )
  end

  defp static_asset?(_), do: false

  defp index_path do
    Application.app_dir(:hivefin, "priv/jellyfin-web/index.html")
  end
end
