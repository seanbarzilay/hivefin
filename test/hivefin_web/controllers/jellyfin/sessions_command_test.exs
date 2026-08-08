defmodule HivefinWeb.Jellyfin.SessionsCommandTest do
  @moduledoc """
  Command-delivery endpoints: `POST /Sessions/:id/Playing[...]`,
  `/Command/:command`, and `/Message` push a WsCommand-shaped message to the
  target's live socket. Also guards:

  - the routing order against swallowing the existing literal
    `/Sessions/Playing*` reporting routes (Task 9 brief risk);
  - the `Id` round-trip: the id a client is ever given (`GET /Sessions`, the
    Sessions socket push) is dashless, but the session registry key is the
    raw dashed access-token id (fix-round C1);
  - real query-string shapes (every value arrives as a string, camelCase
    keys are a real client's, `ItemIds` is CSV) rather than `Plug.Test`
    param injection, which bypasses both query-string and JSON parsing and
    can assert a shape no client can actually produce (fix-round C2);
  - that no credential and no non-scalar value ever reaches the pushed
    `Data` (fix-round I1/I2);
  - that a caller can only command their own sessions (fix-round I4).
  """

  use HivefinWeb.ConnCase, async: false

  alias Hivefin.Jellyfin.Id
  alias Hivefin.Library.LibraryContext
  alias Hivefin.Sessions

  @movies_path Path.expand("test/support/fixtures/media_tree/movies", File.cwd!())

  setup do
    {:ok, user} =
      Hivefin.Accounts.create_user(%{
        name: "Cmd",
        username: "cmduser",
        password: "password1",
        admin: true
      })

    {:ok, token, access_token} =
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

    {:ok, conn: conn, user: user, token: token, access_token: access_token}
  end

  # Registers a fake device socket owned by `user` and returns its dashed
  # session_id — the registry key, and deliberately NOT the dashless id a
  # client is ever shown. Tests that need the client-visible id go through
  # Id.format/1 themselves, exercising the same round-trip a real client does.
  defp register_device(user, device_id \\ "tv") do
    {:ok, _token, target_at} =
      Hivefin.Accounts.issue_token(user, %{
        device_id: device_id,
        device_name: "TV",
        client: "Jellyfin TV",
        client_version: "1.0"
      })

    test = self()

    spawn(fn ->
      Sessions.register(target_at.id, %{user_id: user.id, device_id: device_id})
      send(test, :ready)

      receive do
        {:jellyfin_push, msg} -> send(test, {:pushed, msg})
      end

      Process.sleep(:infinity)
    end)

    assert_receive :ready
    target_at.id
  end

  describe "POST /Sessions/:id/Playing" do
    test "pushes Play, built from a real query string (CSV ItemIds, string ticks)",
         %{conn: conn, user: user} do
      target = register_device(user)

      conn =
        post(
          conn,
          "/Sessions/#{Id.format(target)}/Playing?ItemIds=item-1,item-2&PlayCommand=PlayNow&StartPositionTicks=12345"
        )

      assert conn.status == 204
      assert_receive {:pushed, msg}
      assert msg["MessageType"] == "Play"
      assert msg["Data"]["PlayCommand"] == "PlayNow"
      assert msg["Data"]["ControllingUserId"] == user.id
      assert msg["Data"]["ItemIds"] == ["item-1", "item-2"]
      assert msg["Data"]["StartPositionTicks"] == 12_345
    end

    # Real SDK clients (sendPlayCommand) send camelCase. Before the C2 fix,
    # only the PascalCase keys were read, so this exact request silently lost
    # the real command and fell back to the "PlayNow" default.
    test "accepts camelCase query params like a real SDK client", %{conn: conn, user: user} do
      target = register_device(user)

      conn =
        post(conn, "/Sessions/#{Id.format(target)}/Playing?itemIds=item-1&playCommand=PlayNext")

      assert conn.status == 204
      assert_receive {:pushed, msg}
      assert msg["Data"]["PlayCommand"] == "PlayNext"
      assert msg["Data"]["ItemIds"] == ["item-1"]
    end

    # C1: the id a client is ever given is the dashless wire form (GET
    # /Sessions "Id", the Sessions socket push) — never the raw registry key.
    # Obtaining the id from GET /Sessions (not Ecto.UUID.generate/0) is what
    # makes this test exercise the real bug.
    test "commands the session using the Id GET /Sessions actually advertises",
         %{conn: conn, user: user} do
      target = register_device(user)

      advertised =
        conn
        |> get("/Sessions")
        |> json_response(200)
        |> Enum.find_value(fn s -> s["Id"] == Id.format(target) && s["Id"] end)

      assert advertised, "expected GET /Sessions to advertise the registered device"
      # Sanity: prove this id differs from the raw registry key, or this test
      # would pass even without the coercion fix.
      refute advertised == target

      conn = post(conn, "/Sessions/#{advertised}/Playing?PlayCommand=PlayNow")

      assert conn.status == 204
      assert_receive {:pushed, msg}
      assert msg["Data"]["PlayCommand"] == "PlayNow"
    end

    test "404s when the target has no live socket", %{conn: conn} do
      conn = post(conn, "/Sessions/#{Ecto.UUID.generate()}/Playing?ItemIds=x")

      assert json_response(conn, 404)["error"] == "no_session"
    end

    # I4: ownership is enforced regardless of Id format/liveness — a caller
    # may only command their own sessions. 404 (not 403) so a wrong target
    # doesn't confirm another user's session exists.
    test "cannot command a session registered to a different user", %{conn: conn} do
      {:ok, other_user} =
        Hivefin.Accounts.create_user(%{
          name: "Other",
          username: "otheruser",
          password: "password1",
          admin: true
        })

      target = register_device(other_user)

      conn = post(conn, "/Sessions/#{Id.format(target)}/Playing?PlayCommand=PlayNow")

      assert json_response(conn, 404)["error"] == "no_session"
      refute_receive {:pushed, _msg}
    end
  end

  describe "POST /Sessions/:id/Playing/:command" do
    test "pushes Playstate", %{conn: conn, user: user} do
      target = register_device(user)

      conn = post(conn, "/Sessions/#{Id.format(target)}/Playing/Pause")

      assert conn.status == 204
      assert_receive {:pushed, msg}
      assert msg["MessageType"] == "Playstate"
      assert msg["Data"]["Command"] == "Pause"
    end

    test "Seek from a real query string coerces SeekPositionTicks to an integer",
         %{conn: conn, user: user} do
      target = register_device(user)

      conn = post(conn, "/Sessions/#{Id.format(target)}/Playing/Seek?SeekPositionTicks=12345")

      assert conn.status == 204
      assert_receive {:pushed, msg}
      assert msg["Data"]["Command"] == "Seek"
      assert msg["Data"]["SeekPositionTicks"] == 12_345
    end

    test "400s on an unknown playstate command", %{conn: conn} do
      conn = post(conn, "/Sessions/#{Ecto.UUID.generate()}/Playing/Explode")

      assert json_response(conn, 400)["error"] == "invalid_command"
    end
  end

  describe "POST /Sessions/:id/Command/:command" do
    test "pushes GeneralCommand", %{conn: conn, user: user} do
      target = register_device(user)

      conn = post(conn, "/Sessions/#{Id.format(target)}/Command/SetVolume?Volume=42")

      assert conn.status == 204
      assert_receive {:pushed, msg}
      assert msg["MessageType"] == "GeneralCommand"
      assert msg["Data"]["Name"] == "SetVolume"
      assert msg["Data"]["ControllingUserId"] == user.id
      assert msg["Data"]["Arguments"]["Volume"] == "42"
    end

    # I1: JellyfinAuth also accepts a token via the api_key query param, so a
    # command endpoint that echoed the whole query string into Arguments
    # would forward the caller's own credential to the target device.
    test "does not forward the caller's credential into the command payload",
         %{conn: conn, user: user, token: token} do
      target = register_device(user)

      conn =
        post(conn, "/Sessions/#{Id.format(target)}/Command/SetVolume?Volume=42&api_key=#{token}")

      assert conn.status == 204
      assert_receive {:pushed, msg}
      arguments = msg["Data"]["Arguments"]
      assert arguments["Volume"] == "42"
      refute Map.has_key?(arguments, "api_key")
      refute token in Map.values(arguments)
    end

    # I2: a nested query key (map value) used to raise
    # (Protocol.UndefinedError, String.Chars not implemented for Map),
    # discarding the whole request; a repeated key (list value) used to
    # silently concatenate via List.to_string/1 (["1","2"] -> "12"). Both must
    # be dropped, not stringified.
    test "drops non-scalar Arguments instead of crashing or mis-concatenating",
         %{conn: conn, user: user} do
      target = register_device(user)

      conn =
        post(
          conn,
          "/Sessions/#{Id.format(target)}/Command/SetVolume?Volume=42&Arguments[ItemId]=abc&Bad[]=1&Bad[]=2"
        )

      assert conn.status == 204
      assert_receive {:pushed, msg}
      arguments = msg["Data"]["Arguments"]
      assert arguments["Volume"] == "42"
      refute Map.has_key?(arguments, "Arguments")
      refute Map.has_key?(arguments, "Bad")
    end

    test "cannot command a session registered to a different user", %{conn: conn} do
      {:ok, other_user} =
        Hivefin.Accounts.create_user(%{
          name: "Other2",
          username: "otheruser2",
          password: "password1",
          admin: true
        })

      target = register_device(other_user)

      conn = post(conn, "/Sessions/#{Id.format(target)}/Command/SetVolume?Volume=42")

      assert json_response(conn, 404)["error"] == "no_session"
      refute_receive {:pushed, _msg}
    end
  end

  describe "POST /Sessions/:id/Message" do
    test "pushes a DisplayMessage", %{conn: conn, user: user} do
      target = register_device(user)

      conn = post(conn, "/Sessions/#{Id.format(target)}/Message?Header=Hi&Text=There")

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
    conn = post(build_conn(), "/Sessions/#{Ecto.UUID.generate()}/Playing")

    assert json_response(conn, 401)
  end

  # --- Regression: the new :session_id routes must not swallow the existing
  # literal playback-reporting routes, AND each literal route must still run
  # its own action rather than a sibling one — status 204 alone would not
  # catch either kind of misroute, since :playing/:progress/:stopped (and
  # :capabilities) all 204. The side effect recorded via Sessions.put_state/2
  # differs across all three: :playing always forces is_paused false
  # regardless of the request; :progress reflects the request's own
  # ItemId/PositionTicks/IsPaused; :stopped always forces item_id/
  # position_ticks to nil regardless of the request. Sending the same
  # non-default request body to each and asserting the exact recorded attrs
  # pins which action actually ran.

  describe "existing literal /Sessions/Playing* routes still work" do
    setup %{access_token: access_token} do
      # Conn requests run synchronously in the test process, so registering
      # it as the caller's own socket lets put_state/2 deliver right here —
      # same technique as sessions_playing_test.exs.
      :ok = Sessions.register(access_token.id)

      # report/3's UserData.upsert/3 FK-violates on an item id that isn't a
      # real item, so this needs an actual item — not just a well-formed UUID.
      {:ok, library} =
        LibraryContext.create_library(%{name: "Cmd Movies", type: :movies, path: @movies_path})

      {:ok, movie, :created} =
        LibraryContext.find_or_create_movie(library.id, %{
          name: "Big Buck Bunny",
          production_year: 2008
        })

      {:ok, item_id: movie.id}
    end

    test "POST /Sessions/Playing routes to :playing (forces is_paused false)", %{
      conn: conn,
      item_id: item_id
    } do
      conn = post(conn, "/Sessions/Playing?ItemId=#{item_id}&PositionTicks=100&IsPaused=true")

      assert response(conn, 204)
      assert_receive {:jellyfin_session_state, attrs}
      assert attrs.item_id == item_id
      assert attrs.position_ticks == 100
      assert attrs.is_paused == false
    end

    test "POST /Sessions/Playing/Progress routes to :progress (reflects IsPaused)", %{
      conn: conn,
      item_id: item_id
    } do
      conn =
        post(conn, "/Sessions/Playing/Progress?ItemId=#{item_id}&PositionTicks=999&IsPaused=true")

      assert response(conn, 204)
      assert_receive {:jellyfin_session_state, attrs}
      assert attrs.item_id == item_id
      assert attrs.position_ticks == 999
      assert attrs.is_paused == true
    end

    test "POST /Sessions/Playing/Stopped routes to :stopped (forces nil position)", %{
      conn: conn,
      item_id: item_id
    } do
      conn = post(conn, "/Sessions/Playing/Stopped?ItemId=#{item_id}&PositionTicks=999")

      assert response(conn, 204)
      assert_receive {:jellyfin_session_state, attrs}
      assert attrs.item_id == nil
      assert attrs.position_ticks == nil
      assert attrs.is_paused == false
    end
  end
end
