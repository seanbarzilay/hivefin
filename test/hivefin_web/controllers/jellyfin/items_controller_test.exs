defmodule HivefinWeb.Jellyfin.ItemsControllerTest do
  use HivefinWeb.ConnCase, async: true

  alias Hivefin.Library.LibraryContext

  @movies_path Path.expand("test/support/fixtures/media_tree/movies", File.cwd!())

  setup %{conn: conn} do
    {:ok, user} =
      Hivefin.Accounts.create_user(%{
        name: "Browse",
        username: "browse",
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

    {:ok, conn: conn, user: user, library: library, movie: movie}
  end

  test "GET /Users/:user_id/Views returns libraries as CollectionFolders", %{
    conn: conn,
    user: user,
    library: library
  } do
    conn = get(conn, ~p"/Users/#{user.id}/Views")

    assert %{
             "Items" => items,
             "TotalRecordCount" => 1
           } = json_response(conn, 200)

    assert [view] = items
    assert view["Id"] == library.id
    assert view["Name"] == "Movies"
    assert view["Type"] == "CollectionFolder"
    assert view["CollectionType"] == "movies"
    assert view["IsFolder"] == true
    refute Map.has_key?(view, "Path")
  end

  test "GET /Users/:user_id/Items with ParentId returns movies", %{
    conn: conn,
    user: user,
    library: library,
    movie: movie
  } do
    conn =
      get(conn, ~p"/Users/#{user.id}/Items", %{
        "ParentId" => library.id,
        "IncludeItemTypes" => "Movie"
      })

    assert %{
             "Items" => items,
             "TotalRecordCount" => 1
           } = json_response(conn, 200)

    assert [item] = items
    assert item["Id"] == movie.id
    assert item["Name"] == "Big Buck Bunny"
    assert item["Type"] == "Movie"
    assert item["ProductionYear"] == 2008
    assert item["ParentId"] == library.id
    assert item["IsFolder"] == false
    assert item["UserData"]["Played"] == false
    refute Map.has_key?(item, "Path")
  end

  test "GET /Users/:user_id/Items sorts by ProductionYear", %{
    conn: conn,
    user: user,
    library: library
  } do
    {:ok, older, :created} =
      LibraryContext.find_or_create_movie(library.id, %{name: "Older", production_year: 1990})

    {:ok, newer, :created} =
      LibraryContext.find_or_create_movie(library.id, %{name: "Newer", production_year: 2020})

    conn =
      get(conn, ~p"/Users/#{user.id}/Items", %{
        "ParentId" => library.id,
        "IncludeItemTypes" => "Movie",
        "SortBy" => "ProductionYear"
      })

    assert %{"Items" => items, "TotalRecordCount" => 3} = json_response(conn, 200)
    years = Enum.map(items, & &1["ProductionYear"])
    assert years == Enum.sort(years)
    assert hd(items)["Id"] == older.id
    assert List.last(items)["Id"] == newer.id
  end

  test "GET /Users/:user_id/Items without ParentId returns libraries as folders", %{
    conn: conn,
    user: user,
    library: library
  } do
    conn = get(conn, ~p"/Users/#{user.id}/Items")

    assert %{"Items" => [item], "TotalRecordCount" => 1} = json_response(conn, 200)
    assert item["Id"] == library.id
    assert item["Type"] == "CollectionFolder"
  end

  test "GET /Users/:user_id/Items/:item_id returns single movie", %{
    conn: conn,
    user: user,
    movie: movie
  } do
    conn = get(conn, ~p"/Users/#{user.id}/Items/#{movie.id}")

    assert %{"Id" => id, "Type" => "Movie", "Name" => "Big Buck Bunny"} =
             json_response(conn, 200)

    assert id == movie.id
  end

  test "GET /Users/:user_id/Items/:item_id returns 404 for missing item", %{
    conn: conn,
    user: user
  } do
    missing = Ecto.UUID.generate()
    conn = get(conn, ~p"/Users/#{user.id}/Items/#{missing}")
    assert json_response(conn, 404)
  end

  test "GET /Users/:user_id/Items supports Limit and StartIndex", %{
    conn: conn,
    user: user,
    library: library
  } do
    {:ok, _, :created} =
      LibraryContext.find_or_create_movie(library.id, %{name: "Alpha", production_year: 2001})

    {:ok, _, :created} =
      LibraryContext.find_or_create_movie(library.id, %{name: "Zeta", production_year: 2002})

    conn =
      get(conn, ~p"/Users/#{user.id}/Items", %{
        "ParentId" => library.id,
        "IncludeItemTypes" => "Movie",
        "Limit" => "1",
        "StartIndex" => "0"
      })

    assert %{"Items" => items, "TotalRecordCount" => total} = json_response(conn, 200)
    assert length(items) == 1
    assert total == 3
  end

  test "GET /Items/:item_id/Images/:image_type returns 404 stub", %{conn: conn, movie: movie} do
    conn = get(conn, ~p"/Items/#{movie.id}/Images/Primary")
    assert conn.status == 404
  end

  test "Views requires auth", %{user: user} do
    conn = get(build_conn(), ~p"/Users/#{user.id}/Views")
    assert json_response(conn, 401)
  end
end
