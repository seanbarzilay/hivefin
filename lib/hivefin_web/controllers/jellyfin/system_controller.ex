defmodule HivefinWeb.Jellyfin.SystemController do
  use HivefinWeb, :controller

  alias Hivefin.Jellyfin.SystemInfo

  def public_info(conn, _params) do
    json(conn, SystemInfo.public_info(local_address: request_base_url(conn)))
  end

  def info(conn, _params) do
    json(conn, SystemInfo.info(local_address: request_base_url(conn)))
  end

  @doc """
  Liveness ping used by jellyfin-vue `isConnectedToServer` (getPingSystem).

  When this fails, Vue disables the login form (`:disabled="!isConnectedToServer"`).
  Jellyfin returns the product name as a plain string body.
  """
  def ping(conn, _params) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, SystemInfo.product_name())
  end

  @doc """
  Quick Connect is not implemented; clients probe this during connect.
  """
  def quick_connect_enabled(conn, _params) do
    json(conn, false)
  end

  @doc """
  `GET /System/Endpoint` — EndPointInfo (`IsLocal`, `IsInNetwork`).

  jellyfin-web calls this after login for network policy; treat LAN clients as in-network.
  """
  def endpoint(conn, _params) do
    # Hivefin is a home LAN server; advertise in-network so clients allow DirectPlay etc.
    json(conn, %{
      "IsLocal" => true,
      "IsInNetwork" => true
    })
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

