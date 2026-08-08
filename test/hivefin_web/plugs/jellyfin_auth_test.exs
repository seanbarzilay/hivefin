defmodule HivefinWeb.Plugs.JellyfinAuthTest do
  @moduledoc """
  Every credential form Jellyfin clients actually send must authenticate.

  The `x-mediabrowser-token` case is the one that broke "remember me":
  jellyfin-apiclient's `validateAuthentication` — the call that checks a stored
  session on page load — sends the token *only* in that header. A 401 there
  makes the client discard its saved credentials and show the sign-in screen,
  so every refresh and every app restart demanded a fresh login.
  """
  use HivefinWeb.ConnCase, async: true

  setup do
    {:ok, user} =
      Hivefin.Accounts.create_user(%{
        name: "Auth",
        username: "authplug",
        password: "password1",
        admin: true
      })

    {:ok, token, _access_token} =
      Hivefin.Accounts.issue_token(user, %{
        device_id: "dev-auth",
        device_name: "Chrome",
        client: "Jellyfin Web",
        client_version: "10.10.7"
      })

    {:ok, user: user, token: token}
  end

  # /Users/Me is authenticated and cheap; any authenticated route would do.
  @path "/Users/Me"

  describe "accepted credential forms" do
    test "x-mediabrowser-token header (stored-session validation)", %{token: token} do
      conn = build_conn() |> put_req_header("x-mediabrowser-token", token) |> get(@path)
      assert json_response(conn, 200)
    end

    test "x-emby-token header", %{token: token} do
      conn = build_conn() |> put_req_header("x-emby-token", token) |> get(@path)
      assert json_response(conn, 200)
    end

    test "x-emby-authorization MediaBrowser header", %{token: token} do
      conn =
        build_conn()
        |> put_req_header(
          "x-emby-authorization",
          ~s(MediaBrowser Client="Jellyfin Web", Device="Chrome", DeviceId="dev-auth", Version="10.10.7", Token="#{token}")
        )
        |> get(@path)

      assert json_response(conn, 200)
    end

    test "authorization MediaBrowser header", %{token: token} do
      conn =
        build_conn()
        |> put_req_header(
          "authorization",
          ~s(MediaBrowser Client="Jellyfin Web", Device="Chrome", DeviceId="dev-auth", Version="10.10.7", Token="#{token}")
        )
        |> get(@path)

      assert json_response(conn, 200)
    end

    test "api_key query param", %{token: token} do
      conn = get(build_conn(), @path, %{"api_key" => token})
      assert json_response(conn, 200)
    end
  end

  describe "rejected" do
    test "no credentials" do
      assert json_response(get(build_conn(), @path), 401)
    end

    test "a bogus token in x-mediabrowser-token" do
      conn =
        build_conn() |> put_req_header("x-mediabrowser-token", "not-a-real-token") |> get(@path)

      assert json_response(conn, 401)
    end

    test "an empty x-mediabrowser-token falls through to 401" do
      conn = build_conn() |> put_req_header("x-mediabrowser-token", "") |> get(@path)
      assert json_response(conn, 401)
    end
  end
end
