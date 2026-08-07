defmodule HivefinWeb.Jellyfin.UserControllerTest do
  use HivefinWeb.ConnCase

  test "authenticates and returns AccessToken", %{conn: conn} do
    {:ok, _} =
      Hivefin.Accounts.create_user(%{
        name: "A",
        username: "a",
        password: "password1",
        admin: true
      })

    conn =
      conn
      |> put_req_header(
        "x-emby-authorization",
        ~s(MediaBrowser Client="Test", Device="T", DeviceId="d1", Version="1.0.0")
      )
      |> put_req_header("content-type", "application/json")
      |> post(~p"/Users/AuthenticateByName", %{Username: "a", Pw: "password1"})

    assert %{"AccessToken" => token, "User" => %{"Name" => "A"}} = json_response(conn, 200)
    assert is_binary(token)
  end

  test "rejects bad credentials", %{conn: conn} do
    {:ok, _} =
      Hivefin.Accounts.create_user(%{
        name: "A",
        username: "a",
        password: "password1",
        admin: true
      })

    conn =
      conn
      |> put_req_header(
        "x-emby-authorization",
        ~s(MediaBrowser Client="Test", Device="T", DeviceId="d1", Version="1.0.0")
      )
      |> put_req_header("content-type", "application/json")
      |> post(~p"/Users/AuthenticateByName", %{Username: "a", Pw: "wrong-password"})

    assert json_response(conn, 401)
  end

  test "accepts Password field as well as Pw", %{conn: conn} do
    {:ok, _} =
      Hivefin.Accounts.create_user(%{
        name: "B",
        username: "b",
        password: "password1",
        admin: false
      })

    conn =
      conn
      |> put_req_header(
        "x-emby-authorization",
        ~s(MediaBrowser Client="Test", Device="T", DeviceId="d2", Version="1.0.0")
      )
      |> put_req_header("content-type", "application/json")
      |> post(~p"/Users/AuthenticateByName", %{Username: "b", Password: "password1"})

    assert %{"AccessToken" => _} = json_response(conn, 200)
  end

  test "GET /Users/Me returns current user when authorized", %{conn: conn} do
    {:ok, user} =
      Hivefin.Accounts.create_user(%{
        name: "Me",
        username: "me",
        password: "password1",
        admin: true
      })

    {:ok, token, _} =
      Hivefin.Accounts.issue_token(user, %{
        device_id: "dev",
        device_name: "Dev",
        client: "Test",
        client_version: "1.0"
      })

    conn =
      conn
      |> put_req_header(
        "x-emby-authorization",
        ~s(MediaBrowser Client="Test", Device="Dev", DeviceId="dev", Version="1.0", Token="#{token}")
      )
      |> get(~p"/Users/Me")

    assert %{"Name" => "Me", "Id" => id, "Configuration" => config} = json_response(conn, 200)
    assert id == Hivefin.Jellyfin.Id.format(user.id)
    assert config["HidePlayedInLatest"] == true
  end

  test "GET /Users/:id returns current user (dashed and undashed id)", %{conn: conn} do
    {:ok, user} =
      Hivefin.Accounts.create_user(%{
        name: "ById",
        username: "byid",
        password: "password1",
        admin: true
      })

    {:ok, token, _} =
      Hivefin.Accounts.issue_token(user, %{
        device_id: "dev",
        device_name: "Dev",
        client: "Test",
        client_version: "1.0"
      })

    auth =
      ~s(MediaBrowser Client="Test", Device="Dev", DeviceId="dev", Version="1.0", Token="#{token}")

    undashed = Hivefin.Jellyfin.Id.format(user.id)

    for path <- [~p"/Users/#{user.id}", "/Users/#{undashed}"] do
      resp =
        conn
        |> put_req_header("x-emby-authorization", auth)
        |> get(path)
        |> json_response(200)

      assert resp["Name"] == "ById"
      assert resp["Id"] == undashed
      assert is_map(resp["Configuration"])
      assert resp["Policy"]["EnableMediaPlayback"] == true
    end
  end

  test "GET /Users/Me without token is unauthorized", %{conn: conn} do
    conn = get(conn, ~p"/Users/Me")
    assert json_response(conn, 401)
  end

  test "GET /Users/Me returns 401 after token is revoked", %{conn: conn} do
    {:ok, user} =
      Hivefin.Accounts.create_user(%{
        name: "Revoked",
        username: "revoked",
        password: "password1",
        admin: true
      })

    {:ok, token, _} =
      Hivefin.Accounts.issue_token(user, %{
        device_id: "dev",
        device_name: "Dev",
        client: "Test",
        client_version: "1.0"
      })

    assert {:ok, _} = Hivefin.Accounts.revoke_token(token)

    conn =
      conn
      |> put_req_header(
        "x-emby-authorization",
        ~s(MediaBrowser Client="Test", Device="Dev", DeviceId="dev", Version="1.0", Token="#{token}")
      )
      |> get(~p"/Users/Me")

    assert json_response(conn, 401)
  end
end
