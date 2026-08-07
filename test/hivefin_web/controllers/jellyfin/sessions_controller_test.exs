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

  test "a user with no live socket gets an empty list, not a crash", %{conn: conn} do
    assert [] == conn |> get(~p"/Sessions") |> json_response(200)
  end
end
