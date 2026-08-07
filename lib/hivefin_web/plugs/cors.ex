defmodule HivefinWeb.Plugs.CORS do
  @moduledoc """
  Permissive CORS for Jellyfin SPA clients (e.g. jellyfin-vue) hosted on another origin.

  Reflects the request Origin when present; allows common Emby/Jellyfin auth headers.
  """
  import Plug.Conn

  @allow_headers [
    "accept",
    "authorization",
    "content-type",
    "origin",
    "x-emby-authorization",
    "x-emby-token",
    "x-mediabrowser-token",
    "x-requested-with"
  ]

  def init(opts), do: opts

  def call(conn, _opts) do
    origin = origin_header(conn)

    conn =
      conn
      |> put_resp_header("access-control-allow-origin", origin)
      |> put_resp_header("access-control-allow-methods", "GET, POST, PUT, PATCH, DELETE, OPTIONS, HEAD")
      |> put_resp_header("access-control-allow-headers", Enum.join(@allow_headers, ", "))
      |> put_resp_header("access-control-expose-headers", "content-type, x-request-id")
      |> put_resp_header("access-control-max-age", "86400")
      |> maybe_credentials(origin)
      |> maybe_vary_origin(origin)

    if conn.method == "OPTIONS" do
      conn
      |> send_resp(204, "")
      |> halt()
    else
      conn
    end
  end

  # Browsers reject credentials:true with Allow-Origin: *
  defp maybe_credentials(conn, "*"), do: conn

  defp maybe_credentials(conn, _origin) do
    put_resp_header(conn, "access-control-allow-credentials", "true")
  end


  defp origin_header(conn) do
    case get_req_header(conn, "origin") do
      [origin | _] when origin != "" -> origin
      _ -> "*"
    end
  end

  # Browsers require Vary: Origin when reflecting Origin (not *).
  defp maybe_vary_origin(conn, "*"), do: conn

  defp maybe_vary_origin(conn, _origin) do
    put_resp_header(conn, "vary", "Origin")
  end
end
