defmodule HivefinWeb.Jellyfin.ImagesControllerTest do
  # Mutates :image_cache_dir app env — must not run concurrent with other suites.
  use HivefinWeb.ConnCase, async: false

  alias Hivefin.Library.{Image, LibraryContext, PeopleContext}
  alias Hivefin.Metadata.TMDB
  alias Hivefin.Repo

  setup %{conn: conn} do
    Req.Test.verify_on_exit!()

    {:ok, user} =
      Hivefin.Accounts.create_user(%{
        name: "Img",
        username: "imguser",
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

    tmp =
      Path.join(System.tmp_dir!(), "hivefin-img-ctrl-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp)
    previous = Application.get_env(:hivefin, :image_cache_dir)
    previous_req = Application.get_env(:hivefin, :metadata_req_options)
    Application.put_env(:hivefin, :image_cache_dir, tmp)

    Application.put_env(:hivefin, :metadata_req_options,
      plug: {Req.Test, TMDB},
      retry: false
    )

    on_exit(fn ->
      Application.put_env(:hivefin, :image_cache_dir, previous)
      Application.put_env(:hivefin, :metadata_req_options, previous_req)
      File.rm_rf(tmp)
    end)

    movies_path = Path.expand("test/support/fixtures/media_tree/movies", File.cwd!())

    {:ok, library} =
      LibraryContext.create_library(%{
        name: "Movies",
        type: :movies,
        path: movies_path
      })

    {:ok, movie, :created} =
      LibraryContext.find_or_create_movie(library.id, %{name: "Cached", production_year: 2021})

    file_path = Path.join([tmp, movie.id, "primary.jpg"])
    File.mkdir_p!(Path.dirname(file_path))
    File.write!(file_path, <<0xFF, 0xD8, 0xFF, 0xD9>>)

    {:ok, _image} =
      %Image{}
      |> Image.changeset(%{
        item_id: movie.id,
        type: :primary,
        local_path: file_path,
        provider: "tmdb"
      })
      |> Repo.insert()

    conn =
      conn
      |> put_req_header(
        "x-emby-authorization",
        ~s(MediaBrowser Client="Test", Device="Dev", DeviceId="dev", Version="1.0", Token="#{token}")
      )

    %{conn: conn, movie: movie, file_path: file_path}
  end

  test "GET Primary serves cached file", %{conn: conn, movie: movie, file_path: path} do
    conn = get(conn, ~p"/Items/#{movie.id}/Images/Primary")
    assert conn.status == 200
    assert get_resp_header(conn, "content-type") |> hd() =~ "image/jpeg"
    assert conn.resp_body == File.read!(path)
  end

  test "GET Primary accepts undashed item ids and image Accept header", %{
    conn: conn,
    movie: movie,
    file_path: path
  } do
    undashed = movie.id |> String.replace("-", "")

    conn =
      conn
      |> put_req_header("accept", "image/avif,image/webp,image/*,*/*;q=0.8")
      |> get("/Items/#{undashed}/Images/Primary")

    assert conn.status == 200
    assert conn.resp_body == File.read!(path)
  end

  test "GET Primary works without auth (jellyfin-vue <img src>)", %{
    movie: movie,
    file_path: path
  } do
    # No X-Emby-Authorization — matches browser image tags.
    conn = get(build_conn(), "/Items/#{movie.id}/Images/Primary?format=Webp&quality=90")
    assert conn.status == 200
    assert conn.resp_body == File.read!(path)
  end

  test "GET Backdrop returns 404 when missing", %{conn: conn, movie: movie} do
    conn = get(conn, ~p"/Items/#{movie.id}/Images/Backdrop")
    assert conn.status == 404
  end

  test "GET Primary returns 404 when file gone", %{conn: conn, movie: movie, file_path: path} do
    File.rm!(path)
    conn = get(conn, ~p"/Items/#{movie.id}/Images/Primary")
    assert conn.status == 404
  end

  test "GET Primary lazily fetches and caches an uncached person's headshot", %{conn: conn} do
    lib_path = Path.join(System.tmp_dir!(), "img-ctrl-#{System.unique_integer([:positive])}")
    File.mkdir_p!(lib_path)
    on_exit(fn -> File.rm_rf(lib_path) end)

    {:ok, library} =
      LibraryContext.create_library(%{name: "People", type: :movies, path: lib_path})

    {:ok, movie, :created} =
      LibraryContext.find_or_create_movie(library.id, %{name: "Cast Test", production_year: 2020})

    assert {:ok, 1} =
             PeopleContext.replace_for_item(movie.id, [
               %{
                 tmdb_id: 42,
                 name: "Someone Famous",
                 role: "Themselves",
                 type: "Actor",
                 sort_order: 0,
                 profile_path: "/face.jpg"
               }
             ])

    [entry] = PeopleContext.list_for_item(movie.id)
    body = "headshot-bytes"

    Req.Test.stub(TMDB, fn tmdb_conn ->
      assert tmdb_conn.request_path =~ "/w185/face.jpg"

      tmdb_conn
      |> Plug.Conn.put_resp_content_type("image/jpeg")
      |> Plug.Conn.send_resp(200, body)
    end)

    conn = get(conn, ~p"/Items/#{entry.person.id}/Images/Primary")
    assert conn.status == 200
    assert conn.resp_body == body

    # Second request must be a cache hit: no second Req.Test.stub is
    # configured, so a stub with no match clause raises loudly if this
    # somehow re-downloads instead of serving the cached file.
    conn2 = get(build_conn(), "/Items/#{entry.person.id}/Images/Primary")
    assert conn2.status == 200
    assert conn2.resp_body == body
  end

  test "GET Primary for a person with no profile_path 404s instead of 500ing", %{conn: conn} do
    lib_path = Path.join(System.tmp_dir!(), "img-ctrl-#{System.unique_integer([:positive])}")
    File.mkdir_p!(lib_path)
    on_exit(fn -> File.rm_rf(lib_path) end)

    {:ok, library} =
      LibraryContext.create_library(%{name: "NoPhoto", type: :movies, path: lib_path})

    {:ok, movie, :created} =
      LibraryContext.find_or_create_movie(library.id, %{name: "No Photo", production_year: 2020})

    assert {:ok, 1} =
             PeopleContext.replace_for_item(movie.id, [
               %{
                 tmdb_id: 43,
                 name: "No Photo Person",
                 role: "",
                 type: "Director",
                 sort_order: nil,
                 profile_path: nil
               }
             ])

    [entry] = PeopleContext.list_for_item(movie.id)

    # No Req.Test.stub configured for this test's TMDB plug: any HTTP attempt
    # raises loudly instead of silently succeeding, proving a nil
    # profile_path never reaches TMDB.
    conn = get(conn, ~p"/Items/#{entry.person.id}/Images/Primary")

    assert conn.status == 404
  end
end
