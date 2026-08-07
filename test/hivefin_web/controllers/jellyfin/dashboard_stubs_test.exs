defmodule HivefinWeb.Jellyfin.DashboardStubsTest do
  @moduledoc """
  jellyfin-web's admin dashboard `.map`s these bare arrays and reads `.Items`
  on the query-result shapes. Before this fix, all four paths fell through to
  the SPA catch-all and returned the index.html page with status 200, which
  crashed the dashboard with `TypeError: n.map is not a function`.
  """
  use HivefinWeb.ConnCase, async: true

  setup do
    {:ok, user} =
      Hivefin.Accounts.create_user(%{
        name: "Admin",
        username: "dash_admin",
        password: "password1",
        admin: true
      })

    {:ok, token, _} =
      Hivefin.Accounts.issue_token(user, %{
        device_id: "d1",
        device_name: "Chrome",
        client: "Jellyfin Web",
        client_version: "10.9.0"
      })

    auth =
      ~s(MediaBrowser Client="Jellyfin Web", Device="Chrome", DeviceId="d1", Version="10.9.0", Token="#{token}")

    %{auth: auth}
  end

  defp auth_conn(conn, auth), do: put_req_header(conn, "authorization", auth)

  defp content_type(conn) do
    conn |> get_resp_header("content-type") |> List.first()
  end

  describe "GET /ScheduledTasks" do
    test "returns a bare JSON array, not SPA HTML", %{conn: conn, auth: auth} do
      conn = conn |> auth_conn(auth) |> get(~p"/ScheduledTasks")

      assert conn.status == 200
      assert content_type(conn) =~ "application/json"

      body = response(conn, 200)
      refute String.starts_with?(body, "<")

      assert {:ok, decoded} = Jason.decode(body)
      assert decoded == []
    end

    test "IsEnabled query param is accepted and ignored", %{conn: conn, auth: auth} do
      conn = conn |> auth_conn(auth) |> get(~p"/ScheduledTasks?IsEnabled=true")

      assert conn.status == 200
      assert content_type(conn) =~ "application/json"
      assert json_response(conn, 200) == []
    end
  end

  describe "GET /LiveTv/Recordings" do
    test "returns an empty query result, not SPA HTML", %{conn: conn, auth: auth} do
      conn = conn |> auth_conn(auth) |> get(~p"/LiveTv/Recordings")

      assert conn.status == 200
      assert content_type(conn) =~ "application/json"

      body = response(conn, 200)
      refute String.starts_with?(body, "<")

      assert json_response(conn, 200) == %{
               "Items" => [],
               "TotalRecordCount" => 0,
               "StartIndex" => 0
             }
    end
  end

  describe "GET /web/ConfigurationPages" do
    test "returns a bare JSON array, not the SPA index.html", %{conn: conn, auth: auth} do
      conn = conn |> auth_conn(auth) |> get(~p"/web/ConfigurationPages")

      assert conn.status == 200
      assert content_type(conn) =~ "application/json"

      body = response(conn, 200)
      refute String.starts_with?(body, "<")

      assert {:ok, decoded} = Jason.decode(body)
      assert decoded == []
    end
  end

  describe "GET /System/ActivityLog/Entries" do
    test "returns an empty query result, not SPA HTML", %{conn: conn, auth: auth} do
      conn = conn |> auth_conn(auth) |> get(~p"/System/ActivityLog/Entries")

      assert conn.status == 200
      assert content_type(conn) =~ "application/json"

      body = response(conn, 200)
      refute String.starts_with?(body, "<")

      assert json_response(conn, 200) == %{
               "Items" => [],
               "TotalRecordCount" => 0,
               "StartIndex" => 0
             }
    end
  end

  describe "all four dashboard stubs require auth" do
    test "unauthenticated request 401s as JSON", %{conn: conn} do
      for path <- [
            "/ScheduledTasks",
            "/LiveTv/Recordings",
            "/web/ConfigurationPages",
            "/System/ActivityLog/Entries"
          ] do
        resp = get(conn, path)
        assert resp.status == 401, "#{path} -> #{resp.status}"
        assert %{"error" => _} = json_response(resp, 401)
      end
    end
  end

  describe "safety net: unimplemented paths under the new API roots" do
    test "GET /ScheduledTasks/Running/whatever 404s as JSON, not SPA HTML", %{conn: conn} do
      conn = get(conn, "/ScheduledTasks/Running/whatever")

      assert conn.status == 404
      body = response(conn, 404)
      refute String.starts_with?(body, "<")
      assert {:ok, %{"error" => _}} = Jason.decode(body)
    end

    test "GET /LiveTv/Channels 404s as JSON, not SPA HTML", %{conn: conn} do
      conn = get(conn, "/LiveTv/Channels")

      assert conn.status == 404
      body = response(conn, 404)
      refute String.starts_with?(body, "<")
      assert {:ok, %{"error" => _}} = Jason.decode(body)
    end
  end
end
