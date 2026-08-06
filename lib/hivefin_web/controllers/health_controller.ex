defmodule HivefinWeb.HealthController do
  use HivefinWeb, :controller

  def show(conn, _params) do
    text(conn, "ok")
  end
end
