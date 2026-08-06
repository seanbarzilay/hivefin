defmodule HivefinWeb.Jellyfin.SystemControllerTest do
  use HivefinWeb.ConnCase

  test "GET /System/Info/Public is unauthenticated", %{conn: conn} do
    conn = get(conn, ~p"/System/Info/Public")

    assert %{
             "ServerName" => "Hivefin",
             "ProductName" => "Hivefin",
             "Version" => version,
             "Id" => id,
             "StartupWizardCompleted" => true
           } = json_response(conn, 200)

    assert is_binary(version)
    assert is_binary(id)
    # Do not impersonate Jellyfin product identity
    refute version =~ ~r/jellyfin/i
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
             "ProductName" => "Hivefin",
             "ServerName" => "Hivefin",
             "Id" => _
           } = json_response(conn, 200)
  end
end
