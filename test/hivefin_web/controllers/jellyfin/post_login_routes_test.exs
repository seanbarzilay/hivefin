defmodule HivefinWeb.Jellyfin.PostLoginRoutesTest do
  use HivefinWeb.ConnCase, async: true

  alias Hivefin.Library.LibraryContext

  setup do
    {:ok, user} =
      Hivefin.Accounts.create_user(%{
        name: "Admin",
        username: "admin_postlogin",
        password: "password1",
        admin: true
      })

    {:ok, token, _} =
      Hivefin.Accounts.issue_token(user, %{
        device_id: "vue",
        device_name: "Chrome",
        client: "Jellyfin Web (Vue)",
        client_version: "0.0.0"
      })

    media = Path.expand("test/support/fixtures/media_tree/movies", File.cwd!())

    {:ok, lib} =
      LibraryContext.create_library(%{name: "Movies", type: :movies, path: media})

    :ok = Hivefin.Scanner.scan_library_sync(lib.id)

    auth =
      "MediaBrowser Client=\"Jellyfin%20Web%20(Vue)\", Device=\"Chrome\", DeviceId=\"vue\", Version=\"0.0.0\", Token=\"#{token}\""

    %{user: user, auth: auth, lib: lib}
  end

  defp auth_conn(conn, auth) do
    put_req_header(conn, "authorization", auth)
  end

  test "GET /UserViews returns libraries", %{conn: conn, auth: auth} do
    conn = conn |> auth_conn(auth) |> get(~p"/UserViews")
    body = json_response(conn, 200)
    assert is_list(body["Items"])
    assert body["TotalRecordCount"] >= 1
  end

  test "GET /Items/Latest returns a bare array", %{conn: conn, auth: auth} do
    conn = conn |> auth_conn(auth) |> get(~p"/Items/Latest")
    body = json_response(conn, 200)
    assert is_list(body)
  end

  test "GET /UserItems/Resume returns query result", %{conn: conn, auth: auth} do
    conn = conn |> auth_conn(auth) |> get(~p"/UserItems/Resume")
    body = json_response(conn, 200)
    assert body["Items"] == []
    assert body["TotalRecordCount"] == 0
  end

  test "auth header with encodeURIComponent client still authenticates", %{
    conn: conn,
    user: user
  } do
    conn =
      conn
      |> put_req_header(
        "x-emby-authorization",
        "MediaBrowser Client=\"Jellyfin%20Web%20(Vue)\", Device=\"Chrome\", DeviceId=\"d1\", Version=\"0.0.0\""
      )
      |> put_req_header("content-type", "application/json")
      |> post(~p"/Users/AuthenticateByName", %{Username: user.username, Pw: "password1"})

    body = json_response(conn, 200)
    assert is_binary(body["AccessToken"])
    assert is_binary(body["User"]["Id"])
  end
end
