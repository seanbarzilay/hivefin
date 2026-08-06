defmodule HivefinWeb.Jellyfin.AndroidTvGapsTest do
  @moduledoc """
  Regression tests for Android TV shell gaps (Task 11).
  """

  use HivefinWeb.ConnCase, async: true

  alias Hivefin.Library.{LibraryContext, UserData}

  @movies_path Path.expand("test/support/fixtures/media_tree/movies", File.cwd!())

  setup %{conn: conn} do
    {:ok, user} =
      Hivefin.Accounts.create_user(%{
        name: "TV User",
        username: "tvuser",
        password: "password1",
        admin: true
      })

    {:ok, token, access_token} =
      Hivefin.Accounts.issue_token(user, %{
        device_id: "androidtv-1",
        device_name: "AndroidTV",
        client: "Android TV",
        client_version: "0.17.0"
      })

    conn =
      conn
      |> put_req_header(
        "x-emby-authorization",
        ~s(MediaBrowser Client="Android TV", Device="AndroidTV", DeviceId="androidtv-1", Version="0.17.0", Token="#{token}")
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

    {:ok,
     conn: conn,
     user: user,
     token: token,
     access_token: access_token,
     library: library,
     movie: movie}
  end

  test "GET /Sessions lists device sessions with SessionInfo shape", %{
    conn: conn,
    user: user,
    access_token: access_token
  } do
    conn = get(conn, ~p"/Sessions")
    body = json_response(conn, 200)

    assert is_list(body)
    assert length(body) >= 1

    session = Enum.find(body, &(&1["Id"] == access_token.id))
    assert session
    assert session["UserId"] == user.id
    assert session["UserName"] == user.name
    assert session["Client"] == "Android TV"
    assert session["DeviceId"] == "androidtv-1"
    assert session["DeviceName"] == "AndroidTV"
    assert session["ApplicationVersion"] == "0.17.0"
    assert session["IsActive"] == true
    assert is_map(session["Capabilities"])
  end

  test "GET /Sessions?deviceId= filters sessions", %{conn: conn, access_token: access_token} do
    conn = get(conn, ~p"/Sessions", %{"deviceId" => "androidtv-1"})
    body = json_response(conn, 200)

    assert Enum.all?(body, &(&1["DeviceId"] == "androidtv-1"))
    assert Enum.any?(body, &(&1["Id"] == access_token.id))
  end

  test "GET /Sessions is scoped to the current user", %{
    conn: conn,
    user: user,
    access_token: access_token
  } do
    {:ok, other} =
      Hivefin.Accounts.create_user(%{
        name: "Other",
        username: "other-sessions-#{System.unique_integer([:positive])}",
        password: "password1",
        admin: false
      })

    {:ok, _other_token, other_access} =
      Hivefin.Accounts.issue_token(other, %{
        device_id: "other-device",
        device_name: "Other",
        client: "Other Client",
        client_version: "1.0"
      })

    conn = get(conn, ~p"/Sessions")
    body = json_response(conn, 200)

    assert Enum.all?(body, &(&1["UserId"] == user.id))
    assert Enum.any?(body, &(&1["Id"] == access_token.id))
    refute Enum.any?(body, &(&1["Id"] == other_access.id))
  end

  test "POST /Sessions/Capabilities returns 204", %{conn: conn} do
    conn =
      post(conn, ~p"/Sessions/Capabilities", %{
        "playableMediaTypes" => "Video",
        "supportsMediaControl" => true
      })

    assert response(conn, 204)
  end

  test "POST /Sessions/Capabilities/Full returns 204", %{conn: conn} do
    conn =
      post(conn, ~p"/Sessions/Capabilities/Full", %{
        "PlayableMediaTypes" => ["Video"],
        "SupportedCommands" => ["Play", "Pause", "Stop"],
        "SupportsMediaControl" => true,
        "SupportsPersistentIdentifier" => true
      })

    assert response(conn, 204)
  end

  test "GET /DisplayPreferences/:id returns defaults not 404", %{conn: conn, user: user} do
    conn =
      get(conn, ~p"/DisplayPreferences/usersettings", %{
        "userId" => user.id,
        "client" => "androidtv"
      })

    body = json_response(conn, 200)
    assert body["Id"] == "usersettings"
    assert body["Client"] == "androidtv"
    assert body["UserId"] == user.id
    assert body["SortBy"] == "SortName"
    assert is_map(body["CustomPrefs"])
  end

  test "POST /DisplayPreferences/:id returns 204", %{conn: conn, user: user} do
    conn =
      post(conn, ~p"/DisplayPreferences/usersettings", %{
        "userId" => user.id,
        "SortBy" => "DateCreated",
        "CustomPrefs" => %{}
      })

    assert response(conn, 204)
  end

  test "GET /Users/:id/Items/Resume returns empty QueryResult when none", %{
    conn: conn,
    user: user
  } do
    conn = get(conn, ~p"/Users/#{user.id}/Items/Resume")
    body = json_response(conn, 200)

    assert body["Items"] == []
    assert body["TotalRecordCount"] == 0
    assert body["StartIndex"] == 0
  end

  test "GET /Users/:id/Items/Resume returns in-progress items", %{
    conn: conn,
    user: user,
    movie: movie
  } do
    ticks = UserData.seconds_to_ticks(120)

    assert {:ok, _} =
             UserData.upsert(user.id, movie.id, %{
               playback_position_ticks: ticks,
               played: false,
               played_percentage: 10.0
             })

    conn = get(conn, ~p"/Users/#{user.id}/Items/Resume")
    body = json_response(conn, 200)

    assert body["TotalRecordCount"] == 1
    assert [item] = body["Items"]
    assert item["Id"] == movie.id
    assert item["UserData"]["PlaybackPositionTicks"] == ticks
    assert item["UserData"]["Played"] == false
  end

  test "GET /Shows/NextUp returns empty QueryResult", %{conn: conn, user: user} do
    conn = get(conn, ~p"/Shows/NextUp", %{"UserId" => user.id})
    body = json_response(conn, 200)

    assert body["Items"] == []
    assert body["TotalRecordCount"] == 0
  end

  test "GET /System/Info includes TV-relevant fields", %{conn: conn} do
    conn = get(conn, ~p"/System/Info")
    body = json_response(conn, 200)

    assert body["ProductName"] == "Hivefin"
    assert body["StartupWizardCompleted"] == true
    assert body["HasUpdateAvailable"] == false
    assert is_integer(body["WebSocketPortNumber"])
    assert is_list(body["CastReceiverApplications"])
    assert is_list(body["CompletedInstallations"])
  end

  test "AuthenticateByName SessionInfo includes Id", %{conn: _conn} do
    conn =
      Phoenix.ConnTest.build_conn()
      |> put_req_header(
        "x-emby-authorization",
        ~s(MediaBrowser Client="Android TV", Device="AndroidTV", DeviceId="androidtv-2", Version="0.17.0")
      )
      |> put_req_header("content-type", "application/json")
      |> post(~p"/Users/AuthenticateByName", %{
        "Username" => "tvuser",
        "Pw" => "password1"
      })

    body = json_response(conn, 200)
    assert is_binary(body["SessionInfo"]["Id"])
    assert body["SessionInfo"]["UserId"] == body["User"]["Id"]
    assert body["SessionInfo"]["Client"] == "Android TV"
  end
end
