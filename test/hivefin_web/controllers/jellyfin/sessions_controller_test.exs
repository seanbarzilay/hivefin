defmodule HivefinWeb.Jellyfin.SessionsControllerTest do
  @moduledoc """
  Regression coverage for the live-sessions-only fix: `GET /Sessions` must
  agree with the Sessions websocket push (only sockets that are actually
  connected, not every access token ever issued) and must carry playback
  state so the Dashboard's "Active Devices" panel has something to show.
  """

  use HivefinWeb.ConnCase, async: true

  alias Hivefin.Library.LibraryContext

  @movies_path Path.expand("test/support/fixtures/media_tree/movies", File.cwd!())

  # Listed literally from jellyfin-sdk-kotlin PlayerStateInfo — same
  # discipline as the SessionInfoDto required-key tests elsewhere in this
  # suite. jellyfin-web dereferences `PlayState.IsPaused` with no null guard,
  # so a session missing PlayState crashes the client's socket dispatch chain.
  @play_state_required ~w(CanSeek IsPaused IsMuted RepeatMode PlaybackOrder)

  setup %{conn: conn} do
    {:ok, user} =
      Hivefin.Accounts.create_user(%{
        name: "Sessions REST",
        username: "sessionsrest#{System.unique_integer([:positive])}",
        password: "password1",
        admin: true
      })

    {:ok, token, access_token} =
      Hivefin.Accounts.issue_token(user, %{
        device_id: "dev-rest",
        device_name: "Dev",
        client: "Test",
        client_version: "1.0"
      })

    conn =
      conn
      |> put_req_header(
        "x-emby-authorization",
        ~s(MediaBrowser Client="Test", Device="Dev", DeviceId="dev-rest", Version="1.0", Token="#{token}")
      )
      |> put_req_header("content-type", "application/json")

    {:ok, library} =
      LibraryContext.create_library(%{
        name: "Sessions REST Movies #{System.unique_integer([:positive])}",
        type: :movies,
        path: @movies_path
      })

    {:ok, movie, :created} =
      LibraryContext.find_or_create_movie(library.id, %{
        name: "Big Buck Bunny",
        production_year: 2008
      })

    {:ok, _} =
      %Hivefin.Library.MediaSource{}
      |> Hivefin.Library.MediaSource.changeset(%{
        path: Path.join(System.tmp_dir!(), "hivefin-sessionsrest-#{movie.id}.mp4"),
        container: "mp4",
        duration_ticks: 60_000_000,
        item_id: movie.id
      })
      |> Hivefin.Repo.insert()

    {:ok, conn: conn, user: user, access_token: access_token, movie: movie}
  end

  test "GET /Sessions returns only sessions with a live socket", %{
    conn: conn,
    user: user,
    access_token: access_token
  } do
    # Conn requests run synchronously in the test process, so registering it
    # as the "socket" for this session is enough to make it live.
    :ok = Hivefin.Sessions.register(access_token.id, %{user_id: user.id, device_id: "dev-rest"})

    # A second, never-connected token for the same user — the "dead row"
    # shape from the production regression (146 of 147 sessions were this).
    {:ok, _dead_token, dead_at} =
      Hivefin.Accounts.issue_token(user, %{
        device_id: "dead-device",
        device_name: "Dead",
        client: "Old Client",
        client_version: "1.0"
      })

    body = conn |> get(~p"/Sessions") |> json_response(200)

    assert body != [], "expected the live session to be present"

    ids = Enum.map(body, & &1["Id"])
    assert Hivefin.Jellyfin.Id.format(access_token.id) in ids
    refute Hivefin.Jellyfin.Id.format(dead_at.id) in ids
  end

  test "GET /Sessions carries NowPlayingItem and PlayState for a playing session", %{
    conn: conn,
    user: user,
    access_token: access_token,
    movie: movie
  } do
    :ok = Hivefin.Sessions.register(access_token.id, %{user_id: user.id, device_id: "dev-rest"})

    :ok =
      Hivefin.Sessions.update(access_token.id, %{
        item_id: Hivefin.Jellyfin.Id.format(movie.id),
        position_ticks: 500,
        is_paused: false
      })

    body = conn |> get(~p"/Sessions") |> json_response(200)

    session = Enum.find(body, &(&1["Id"] == Hivefin.Jellyfin.Id.format(access_token.id)))
    assert session, "expected a session entry for the live socket"

    refute is_nil(session["NowPlayingItem"])
    refute is_nil(session["NowPlayingItem"]["RunTimeTicks"])
    assert session["PlayState"]["PositionTicks"] == 500
  end

  # Both emitters build their payload from Sessions.live_for_user/2, which
  # only returns access tokens with a live socket — so within that set every
  # session is controllable, and the REST list and the socket push must agree.
  test "GET /Sessions and the Sessions socket push agree on capability for the same session", %{
    conn: conn,
    user: user,
    access_token: access_token
  } do
    :ok = Hivefin.Sessions.register(access_token.id, %{user_id: user.id, device_id: "dev-rest"})

    rest_body = conn |> get(~p"/Sessions") |> json_response(200)
    assert rest_body != [], "expected the live session to be present"

    rest_session =
      Enum.find(rest_body, &(&1["Id"] == Hivefin.Jellyfin.Id.format(access_token.id)))

    assert rest_session, "expected a REST session entry for the live socket"

    socket_state = %{
      user_id: user.id,
      session_id: access_token.id,
      device_id: "dev-rest",
      subscriptions: MapSet.new()
    }

    {:push, _, socket_state} = HivefinWeb.JellyfinSocket.init(socket_state)

    {:push, {:text, json}, _} =
      HivefinWeb.JellyfinSocket.handle_in(
        {Jason.encode!(%{"MessageType" => "SessionsStart"}), [opcode: :text]},
        socket_state
      )

    socket_sessions = Jason.decode!(json)["Data"]
    assert socket_sessions != [], "expected at least one session in the Sessions push"

    socket_session =
      Enum.find(socket_sessions, &(&1["Id"] == Hivefin.Jellyfin.Id.format(access_token.id)))

    assert socket_session, "expected a socket push entry for the live socket"

    assert rest_session["SupportsMediaControl"] == socket_session["SupportsMediaControl"]
    assert rest_session["SupportsRemoteControl"] == socket_session["SupportsRemoteControl"]
    assert rest_session["SupportedCommands"] == socket_session["SupportedCommands"]

    # Not just "agree" — a live socket must actually be reported controllable.
    assert rest_session["SupportsMediaControl"] == true
    assert rest_session["SupportsRemoteControl"] == true
    # Task 9 delivers commands now — no longer [].
    assert rest_session["SupportedCommands"] ==
             Hivefin.Jellyfin.Dto.Session.supported_commands()
  end

  test "a user with no live socket gets an empty list, not a crash", %{conn: conn} do
    assert [] == conn |> get(~p"/Sessions") |> json_response(200)
  end

  test "GET /Sessions carries PlayState with all 5 required fields for an idle session", %{
    conn: conn,
    user: user,
    access_token: access_token
  } do
    :ok = Hivefin.Sessions.register(access_token.id, %{user_id: user.id, device_id: "dev-rest"})

    body = conn |> get(~p"/Sessions") |> json_response(200)
    assert body != [], "expected the live session to be present"

    session = Enum.find(body, &(&1["Id"] == Hivefin.Jellyfin.Id.format(access_token.id)))
    assert session, "expected a session entry for the live socket"

    play_state = session["PlayState"]
    assert play_state, "expected PlayState to be present even when idle"

    for key <- @play_state_required do
      assert Map.has_key?(play_state, key), "PlayState missing #{key}"
    end

    assert play_state["CanSeek"] == false
    assert play_state["IsPaused"] == false
    refute Map.has_key?(session, "NowPlayingItem")
  end
end
