defmodule HivefinWeb.Jellyfin.SystemController do
  use HivefinWeb, :controller

  alias Hivefin.Jellyfin.SystemInfo

  def public_info(conn, _params) do
    json(conn, SystemInfo.public_info())
  end

  def info(conn, _params) do
    json(conn, SystemInfo.info())
  end
end
