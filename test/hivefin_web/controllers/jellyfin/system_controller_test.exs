defmodule HivefinWeb.Jellyfin.SystemControllerTest do
  use HivefinWeb.ConnCase

  test "GET /System/Info/Public is unauthenticated with Jellyfin discovery identity", %{
    conn: conn
  } do
    conn = get(conn, ~p"/System/Info/Public")

    assert %{
             "ServerName" => "Hivefin",
             "ProductName" => "Jellyfin Server",
             "Version" => version,
             "Id" => id,
             "StartupWizardCompleted" => true
           } = json_response(conn, 200)

    # jellyfin-vue / @jellyfin/sdk require ProductName exact match and Version >= API_VERSION
    assert version == "12.0.0"
    assert is_binary(id)
  end

  test "GET /System/Info requires auth", %{conn: conn} do
    conn = get(conn, ~p"/System/Info")
    assert json_response(conn, 401)
  end

  test "GET /System/Info with valid token", %{conn: conn} do
    {:ok, user} =
      Hivefin.Accounts.create_user(%{
        name: "A",
        username: "sysuser",
        password: "password1",
        admin: true
      })

    {:ok, token, _} =
      Hivefin.Accounts.issue_token(user, %{
        device_id: "d1",
        device_name: "T",
        client: "Test",
        client_version: "1.0"
      })

    conn =
      conn
      |> put_req_header(
        "authorization",
        ~s(MediaBrowser Client="Test", Device="T", DeviceId="d1", Version="1.0", Token="#{token}")
      )
      |> get(~p"/System/Info")

    assert %{
             "ProductName" => "Jellyfin Server",
             "ServerName" => "Hivefin",
             "Version" => "12.0.0",
             "Id" => _
           } = json_response(conn, 200)
  end

  test "GET /Branding/Configuration is public", %{conn: conn} do
    conn = get(conn, ~p"/Branding/Configuration")

    assert %{
             "LoginDisclaimer" => "",
             "CustomCss" => "",
             "SplashscreenEnabled" => false
           } = json_response(conn, 200)
  end

  test "GET /Users/Public returns empty list", %{conn: conn} do
    conn = get(conn, ~p"/Users/Public")
    assert json_response(conn, 200) == []
  end

  test "GET /System/Ping returns product name for connection check", %{conn: conn} do
    conn = get(conn, ~p"/System/Ping")
    assert text_response(conn, 200) == "Jellyfin Server"
  end

  test "POST /System/Ping also works", %{conn: conn} do
    conn = post(conn, ~p"/System/Ping")
    assert text_response(conn, 200) == "Jellyfin Server"
  end
end

