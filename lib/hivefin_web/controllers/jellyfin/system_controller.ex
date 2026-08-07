defmodule HivefinWeb.Jellyfin.SystemController do
  use HivefinWeb, :controller

  alias Hivefin.Jellyfin.SystemInfo

  def public_info(conn, _params) do
    json(conn, SystemInfo.public_info(local_address: request_base_url(conn)))
  end

  def info(conn, _params) do
    json(conn, SystemInfo.info(local_address: request_base_url(conn)))
  end

  defp request_base_url(conn) do
    scheme = Atom.to_string(conn.scheme)
    host = conn.host
    port = conn.port

    default_port? =
      (scheme == "http" and port == 80) or (scheme == "https" and port == 443)

    if default_port? do
      "#{scheme}://#{host}"
    else
      "#{scheme}://#{host}:#{port}"
    end
  end
end

