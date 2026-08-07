defmodule HivefinWeb.Plugs.CORSTest do
  use HivefinWeb.ConnCase, async: true

  test "OPTIONS preflight returns 204 with CORS headers", %{conn: conn} do
    conn =
      conn
      |> put_req_header("origin", "http://localhost:3000")
      |> put_req_header("access-control-request-method", "GET")
      |> options(~p"/System/Info/Public")

    assert conn.status == 204
    assert get_resp_header(conn, "access-control-allow-origin") == ["http://localhost:3000"]
    assert get_resp_header(conn, "access-control-allow-credentials") == ["true"]

    [methods] = get_resp_header(conn, "access-control-allow-methods")
    assert methods =~ "GET"
    assert methods =~ "POST"

    [headers] = get_resp_header(conn, "access-control-allow-headers")
    assert headers =~ "x-emby-authorization"
  end

  test "GET System/Info/Public reflects origin and request host", %{conn: conn} do
    conn =
      conn
      |> Map.put(:host, "192.168.1.244")
      |> Map.put(:port, 4000)
      |> put_req_header("origin", "https://jellyfin-vue.example")
      |> get(~p"/System/Info/Public")

    assert %{"LocalAddress" => local, "ServerName" => "Hivefin"} = json_response(conn, 200)
    assert local == "http://192.168.1.244:4000"
    assert get_resp_header(conn, "access-control-allow-origin") == ["https://jellyfin-vue.example"]
  end
end
