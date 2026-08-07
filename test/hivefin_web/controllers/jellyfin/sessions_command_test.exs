defmodule HivefinWeb.Jellyfin.SessionsCommandTest do
  @moduledoc """
  Command-delivery endpoints: `POST /Sessions/:id/Playing[...]`,
  `/Command/:command`, and `/Message` push a WsCommand-shaped message to the
  target's live socket. Also guards the routing order against swallowing the
  existing literal `/Sessions/Playing*` reporting routes (Task 9 brief risk).
  """

  use HivefinWeb.ConnCase, async: false

  alias Hivefin.Sessions

  setup do
    {:ok, user} =
      Hivefin.Accounts.create_user(%{
        name: "Cmd",
        username: "cmduser",
        password: "password1",
        admin: true
      })

    {:ok, token, _at} =
      Hivefin.Accounts.issue_token(user, %{
        device_id: "phone",
        device_name: "Phone",
        client: "Jellyfin Web",
        client_version: "10.9.0"
      })

    conn =
      build_conn()
      |> put_req_header(
        "x-emby-authorization",
        ~s(MediaBrowser Client="Jellyfin Web", Device="Phone", DeviceId="phone", Version="10.9.0", Token="#{token}")
      )

    {:ok, conn: conn, user: user}
  end

  # Stands in for a TV's socket process.
  defp fake_target(session_id) do
    test = self()

    pid =
      spawn(fn ->
        Sessions.register(session_id, %{user_id: "tv"})
        send(test, :ready)

        receive do
          {:jellyfin_push, msg} -> send(test, {:pushed, msg})
        end

        Process.sleep(:infinity)
      end)

    assert_receive :ready
    pid
  end

  describe "POST /Sessions/:id/Playing" do
    test "pushes Play to the target", %{conn: conn, user: user} do
      target = Ecto.UUID.generate()
      fake_target(target)

      conn =
        post(conn, "/Sessions/#{target}/Playing", %{
          "ItemIds" => ["item-1"],
          "PlayCommand" => "PlayNow"
        })

      assert conn.status == 204
      assert_receive {:pushed, msg}
      assert msg["MessageType"] == "Play"
      assert msg["Data"]["PlayCommand"] == "PlayNow"
      assert msg["Data"]["ControllingUserId"] == user.id
      assert msg["Data"]["ItemIds"] == ["item-1"]
    end

    test "404s when the target has no live socket", %{conn: conn} do
      conn = post(conn, "/Sessions/#{Ecto.UUID.generate()}/Playing", %{"ItemIds" => ["x"]})

      assert json_response(conn, 404)["error"] == "no_session"
    end
  end

  describe "POST /Sessions/:id/Playing/:command" do
    test "pushes Playstate", %{conn: conn} do
      target = Ecto.UUID.generate()
      fake_target(target)

      conn = post(conn, "/Sessions/#{target}/Playing/Pause", %{})

      assert conn.status == 204
      assert_receive {:pushed, msg}
      assert msg["MessageType"] == "Playstate"
      assert msg["Data"]["Command"] == "Pause"
    end

    test "Seek carries SeekPositionTicks", %{conn: conn} do
      target = Ecto.UUID.generate()
      fake_target(target)

      conn = post(conn, "/Sessions/#{target}/Playing/Seek", %{"SeekPositionTicks" => 12_345})

      assert conn.status == 204
      assert_receive {:pushed, msg}
      assert msg["Data"]["Command"] == "Seek"
      assert msg["Data"]["SeekPositionTicks"] == 12_345
    end

    test "400s on an unknown playstate command", %{conn: conn} do
      target = Ecto.UUID.generate()
      fake_target(target)

      conn = post(conn, "/Sessions/#{target}/Playing/Explode", %{})

      assert json_response(conn, 400)["error"] == "invalid_command"
    end
  end

  describe "POST /Sessions/:id/Command/:command" do
    test "pushes GeneralCommand", %{conn: conn, user: user} do
      target = Ecto.UUID.generate()
      fake_target(target)

      conn = post(conn, "/Sessions/#{target}/Command/SetVolume", %{"Volume" => 42})

      assert conn.status == 204
      assert_receive {:pushed, msg}
      assert msg["MessageType"] == "GeneralCommand"
      assert msg["Data"]["Name"] == "SetVolume"
      assert msg["Data"]["ControllingUserId"] == user.id
      assert msg["Data"]["Arguments"]["Volume"] == "42"
    end
  end

  describe "POST /Sessions/:id/Message" do
    test "pushes a DisplayMessage", %{conn: conn, user: user} do
      target = Ecto.UUID.generate()
      fake_target(target)

      conn = post(conn, "/Sessions/#{target}/Message", %{"Header" => "Hi", "Text" => "There"})

      assert conn.status == 204
      assert_receive {:pushed, msg}
      assert msg["MessageType"] == "GeneralCommand"
      assert msg["Data"]["Name"] == "DisplayMessage"
      assert msg["Data"]["ControllingUserId"] == user.id
      assert msg["Data"]["Arguments"]["Header"] == "Hi"
      assert msg["Data"]["Arguments"]["Text"] == "There"
    end
  end

  test "requires authentication" do
    conn = post(build_conn(), "/Sessions/#{Ecto.UUID.generate()}/Playing", %{})

    assert json_response(conn, 401)
  end

  # --- Regression: the new :session_id routes must not swallow the existing
  # literal playback-reporting routes. If they did, session_id would bind to
  # "Playing" and the literal suffix ("Progress"/"Stopped") would be treated
  # as a playstate `command` — none of which are valid playstate commands, so
  # a swallow would surface as 400 invalid_command instead of the real 204.

  describe "existing literal /Sessions/Playing* routes still work" do
    test "POST /Sessions/Playing still routes to :playing (not swallowed as session_id)", %{
      conn: conn
    } do
      conn = post(conn, "/Sessions/Playing", %{})

      assert response(conn, 204)
    end

    test "POST /Sessions/Playing/Progress still routes to :progress, not :playstate", %{
      conn: conn
    } do
      conn =
        post(conn, "/Sessions/Playing/Progress", %{"PositionTicks" => 100, "IsPaused" => false})

      assert response(conn, 204)
    end

    test "POST /Sessions/Playing/Stopped still routes to :stopped, not :playstate", %{
      conn: conn
    } do
      conn = post(conn, "/Sessions/Playing/Stopped", %{})

      assert response(conn, 204)
    end
  end
end
