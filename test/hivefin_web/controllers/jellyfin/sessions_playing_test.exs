defmodule HivefinWeb.Jellyfin.SessionsPlayingTest do
  use HivefinWeb.ConnCase, async: true

  alias Hivefin.Library.{LibraryContext, UserData}

  @movies_path Path.expand("test/support/fixtures/media_tree/movies", File.cwd!())

  setup %{conn: conn} do
    {:ok, user} =
      Hivefin.Accounts.create_user(%{
        name: "Progress",
        username: "progress",
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
      |> put_req_header("content-type", "application/json")

    {:ok, library} =
      LibraryContext.create_library(%{
        name: "Movies",
        type: :movies,
        path: @movies_path
      })

    {:ok, movie, :created} =
      LibraryContext.find_or_create_movie(library.id, %{
        name: "Big Buck Bunny",
        production_year: 2008
      })

    {:ok, conn: conn, user: user, movie: movie}
  end

  test "POST /Sessions/Playing/Progress upserts UserData ticks", %{
    conn: conn,
    user: user,
    movie: movie
  } do
    ticks = UserData.seconds_to_ticks(120)

    conn =
      post(conn, ~p"/Sessions/Playing/Progress", %{
        "ItemId" => movie.id,
        "PositionTicks" => ticks,
        "IsPaused" => false,
        "PlaySessionId" => "session-1"
      })

    assert response(conn, 204)

    ud = UserData.get(user.id, movie.id)
    assert ud.playback_position_ticks == ticks
    assert %DateTime{} = ud.last_played_date
  end

  test "POST /Sessions/Playing then Stopped updates position", %{
    conn: conn,
    user: user,
    movie: movie
  } do
    start_ticks = UserData.seconds_to_ticks(5)
    stop_ticks = UserData.seconds_to_ticks(300)
    # Runtime 20 min so 300s is mid-play (not auto-complete)
    insert_source!(movie.id, UserData.seconds_to_ticks(1200))

    conn1 =
      post(conn, ~p"/Sessions/Playing", %{
        "ItemId" => movie.id,
        "PositionTicks" => start_ticks
      })

    assert response(conn1, 204)

    conn2 =
      post(conn, ~p"/Sessions/Playing/Stopped", %{
        "ItemId" => movie.id,
        "PositionTicks" => stop_ticks
      })

    assert response(conn2, 204)

    ud = UserData.get(user.id, movie.id)
    assert ud.playback_position_ticks == stop_ticks
    assert ud.played == false
    assert ud.played_percentage == 25.0
  end

  test "POST /Sessions/Playing/Stopped near end marks played and clears resume", %{
    conn: conn,
    user: user,
    movie: movie
  } do
    runtime = UserData.seconds_to_ticks(100)
    insert_source!(movie.id, runtime)
    # 95% of runtime — past Jellyfin-style 90% threshold
    stop_ticks = trunc(runtime * 0.95)

    conn =
      post(conn, ~p"/Sessions/Playing/Stopped", %{
        "ItemId" => movie.id,
        "PositionTicks" => stop_ticks
      })

    assert response(conn, 204)

    ud = UserData.get(user.id, movie.id)
    assert ud.played == true
    assert ud.playback_position_ticks == 0
    assert ud.played_percentage == 100.0
    assert ud.play_count == 1
  end

  test "POST Progress at exact runtime marks complete", %{
    conn: conn,
    user: user,
    movie: movie
  } do
    runtime = 60_416_670
    insert_source!(movie.id, runtime)

    conn =
      post(conn, ~p"/Sessions/Playing/Progress", %{
        "ItemId" => movie.id,
        "PositionTicks" => runtime,
        "IsPaused" => false
      })

    assert response(conn, 204)

    ud = UserData.get(user.id, movie.id)
    assert ud.played == true
    assert ud.playback_position_ticks == 0
  end

  defp insert_source!(item_id, duration_ticks) do
    {:ok, _} =
      %Hivefin.Library.MediaSource{}
      |> Hivefin.Library.MediaSource.changeset(%{
        path: Path.join(System.tmp_dir!(), "hivefin-progress-#{item_id}.mp4"),
        container: "mp4",
        duration_ticks: duration_ticks,
        item_id: item_id
      })
      |> Hivefin.Repo.insert()
  end

  test "GET item embeds UserData PlaybackPositionTicks after progress", %{
    conn: conn,
    user: user,
    movie: movie
  } do
    ticks = UserData.seconds_to_ticks(90)

    assert {:ok, _} =
             UserData.upsert(user.id, movie.id, %{
               playback_position_ticks: ticks,
               played_percentage: 25.0,
               played: false
             })

    conn = get(conn, ~p"/Users/#{user.id}/Items/#{movie.id}")
    body = json_response(conn, 200)

    assert body["UserData"]["PlaybackPositionTicks"] == ticks
    assert body["UserData"]["PlayedPercentage"] == 25.0
    assert body["UserData"]["Played"] == false
  end

  test "GET items list embeds UserData for current user", %{
    conn: conn,
    user: user,
    movie: movie
  } do
    ticks = 50_000_000

    assert {:ok, _} =
             UserData.upsert(user.id, movie.id, %{
               playback_position_ticks: ticks,
               played: true,
               played_percentage: 100.0
             })

    # Parent is library from movie.library_id
    library_id = movie.library_id

    conn =
      get(conn, ~p"/Users/#{user.id}/Items", %{
        "ParentId" => library_id,
        "IncludeItemTypes" => "Movie"
      })

    assert %{"Items" => [item]} = json_response(conn, 200)
    assert item["Id"] == Hivefin.Jellyfin.Id.format(movie.id)
    assert item["UserData"]["PlaybackPositionTicks"] == ticks
    assert item["UserData"]["Played"] == true
    assert item["UserData"]["PlayedPercentage"] == 100.0
  end
end
