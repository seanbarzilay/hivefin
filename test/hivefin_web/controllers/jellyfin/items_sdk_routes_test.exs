defmodule HivefinWeb.Jellyfin.ItemsSdkRoutesTest do
  @moduledoc """
  Modern SDK paths used by jellyfin-vue item/library pages:
  - GET /Items/:id (getItem)
  - GET /Items?ids=... (library folder)
  - GET /Items?parentId=... (library children)
  """
  use HivefinWeb.ConnCase, async: true

  alias Hivefin.Jellyfin.Id
  alias Hivefin.Library.LibraryContext

  @movies_path Path.expand("test/support/fixtures/media_tree/movies", File.cwd!())

  setup %{conn: conn} do
    {:ok, user} =
      Hivefin.Accounts.create_user(%{
        name: "Sdk",
        username: "sdkuser",
        password: "password1",
        admin: true
      })

    {:ok, token, _} =
      Hivefin.Accounts.issue_token(user, %{
        device_id: "sdk",
        device_name: "Chrome",
        client: "Vue",
        client_version: "1"
      })

    {:ok, lib} =
      LibraryContext.create_library(%{name: "Movies", type: :movies, path: @movies_path})

    :ok = Hivefin.Scanner.scan_library_sync(lib.id)
    [movie] = LibraryContext.list_items(lib.id, type: :movie)

    auth =
      "MediaBrowser Client=\"Vue\", Device=\"Chrome\", DeviceId=\"sdk\", Version=\"1\", Token=\"#{token}\""

    %{conn: put_req_header(conn, "authorization", auth), lib: lib, movie: movie}
  end

  test "GET /Items/:id returns movie", %{conn: conn, movie: movie} do
    conn = get(conn, ~p"/Items/#{Id.format(movie.id)}")
    body = json_response(conn, 200)
    assert body["Id"] == Id.format(movie.id)
    assert body["Type"] == "Movie"
    assert body["MediaType"] == "Video"
    assert is_list(body["MediaSources"])
  end

  test "GET /Items/:id with dashed uuid still works", %{conn: conn, movie: movie} do
    conn = get(conn, ~p"/Items/#{movie.id}")
    assert json_response(conn, 200)["Id"] == Id.format(movie.id)
  end

  test "GET /Items?ids= returns library folder", %{conn: conn, lib: lib} do
    conn = get(conn, ~p"/Items", %{"ids" => Id.format(lib.id)})
    body = json_response(conn, 200)
    assert body["TotalRecordCount"] == 1
    assert hd(body["Items"])["Id"] == Id.format(lib.id)
    assert hd(body["Items"])["Type"] == "CollectionFolder"
    assert hd(body["Items"])["CollectionType"] == "movies"
  end

  test "GET /Items?parentId= lists movies in library", %{conn: conn, lib: lib, movie: movie} do
    conn =
      get(conn, ~p"/Items", %{
        "parentId" => Id.format(lib.id),
        "includeItemTypes" => "Movie",
        "recursive" => "true"
      })

    body = json_response(conn, 200)
    ids = Enum.map(body["Items"], & &1["Id"])
    assert Id.format(movie.id) in ids
  end
end
