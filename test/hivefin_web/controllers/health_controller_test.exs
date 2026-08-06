defmodule HivefinWeb.HealthControllerTest do
  use HivefinWeb.ConnCase

  test "GET /healthz", %{conn: conn} do
    conn = get(conn, ~p"/healthz")
    assert text_response(conn, 200) == "ok"
  end
end
