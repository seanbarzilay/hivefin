defmodule HivefinWeb.Jellyfin.ImagesControllerTest do
  # Mutates :image_cache_dir app env — must not run concurrent with other suites.
  use HivefinWeb.ConnCase, async: false

  alias Hivefin.Library.{Image, LibraryContext}
  alias Hivefin.Repo

  setup %{conn: conn} do
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
    Application.put_env(:hivefin, :image_cache_dir, tmp)

    on_exit(fn ->
      Application.put_env(:hivefin, :image_cache_dir, previous)
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

  test "GET Backdrop returns 404 when missing", %{conn: conn, movie: movie} do
    conn = get(conn, ~p"/Items/#{movie.id}/Images/Backdrop")
    assert conn.status == 404
  end

  test "GET Primary returns 404 when file gone", %{conn: conn, movie: movie, file_path: path} do
    File.rm!(path)
    conn = get(conn, ~p"/Items/#{movie.id}/Images/Primary")
    assert conn.status == 404
  end
end
