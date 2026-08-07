defmodule HivefinWeb.WebClientController do
  @moduledoc """
  Serves the bundled Jellyfin web UI (SPA fallback to index.html).

  Official Jellyfin Android/TV apps are WebViews that `loadUrl(serverRoot)` and
  expect `main.*.bundle.js` from jellyfin-web. Without this, connect fails
  even when `/System/Info/Public` works.
  """
  use HivefinWeb, :controller

  @doc """
  Serves `priv/jellyfin-web/index.html` for SPA client-side routes.
  """
  def index(conn, _params) do
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

  defp index_path do
    Application.app_dir(:hivefin, "priv/jellyfin-web/index.html")
  end
end
