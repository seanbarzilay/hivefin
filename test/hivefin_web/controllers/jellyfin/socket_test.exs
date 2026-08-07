defmodule HivefinWeb.Jellyfin.SocketTest do
  use HivefinWeb.ConnCase, async: true

  setup do
    {:ok, user} =
      Hivefin.Accounts.create_user(%{
        name: "Socket",
        username: "socketuser",
        password: "password1",
        admin: true
      })

    {:ok, token, access_token} =
      Hivefin.Accounts.issue_token(user, %{
        device_id: "pixel",
        device_name: "Pixel",
        client: "Jellyfin for Android",
        client_version: "2.6.3"
      })

    {:ok, user: user, token: token, access_token: access_token}
  end

  # WebSockAdapter.upgrade/4 validates these per RFC6455 and raises otherwise.
  # `host` is required as a literal req_headers entry, distinct from conn.host.
  # Plug.Adapters.Test.Conn sets conn.host but never mirrors it into
  # req_headers, and Plug.Conn.put_req_header/3 refuses "host" outright
  # (it insists on `%Plug.Conn{conn | host: ...}` instead) — so it has to be
  # spliced into req_headers directly here, test-only.
  defp ws_headers(conn) do
    conn
    |> Map.update!(:req_headers, &[{"host", conn.host} | &1])
    |> put_req_header("connection", "upgrade")
    |> put_req_header("upgrade", "websocket")
    |> put_req_header("sec-websocket-key", Base.encode64("0123456789abcdef"))
    |> put_req_header("sec-websocket-version", "13")
  end

  test "upgrades with api_key query param", %{token: token, access_token: at, user: user} do
    conn =
      build_conn()
      |> ws_headers()
      |> get("/socket?api_key=#{token}&deviceId=pixel")

    assert conn.state == :upgraded
    assert_received {_ref, :upgrade, {:websocket, {HivefinWeb.JellyfinSocket, state, _opts}}}
    assert state.session_id == at.id
    assert state.user_id == user.id
  end

  test "upgrades with MediaBrowser Authorization header", %{token: token} do
    conn =
      build_conn()
      |> ws_headers()
      |> put_req_header(
        "authorization",
        ~s(MediaBrowser Client="Jellyfin for Android", Device="Pixel", DeviceId="pixel", Version="2.6.3", Token="#{token}")
      )
      |> get("/socket")

    assert conn.state == :upgraded
    assert_received {_ref, :upgrade, {:websocket, {HivefinWeb.JellyfinSocket, _state, _opts}}}
  end

  test "401s without credentials" do
    conn = build_conn() |> ws_headers() |> get("/socket")

    assert json_response(conn, 401)
    refute conn.state == :upgraded
  end

  test "401s with a bogus token" do
    conn = build_conn() |> ws_headers() |> get("/socket?api_key=not-a-real-token")

    assert json_response(conn, 401)
  end

  test "a client-supplied deviceId is not used as the session key", %{
    token: token,
    access_token: at
  } do
    conn =
      build_conn()
      |> ws_headers()
      |> get("/socket?api_key=#{token}&deviceId=someone-elses-device")

    assert conn.state == :upgraded
    assert_received {_ref, :upgrade, {:websocket, {HivefinWeb.JellyfinSocket, state, _opts}}}
    # Session identity comes from the token, never the query string.
    assert state.session_id == at.id
  end
end
