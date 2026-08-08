defmodule Hivefin.Metadata.ImageCacheTest do
  use Hivefin.DataCase, async: false

  alias Hivefin.Library.{Image, LibraryContext}
  alias Hivefin.Metadata.ImageCache
  alias Hivefin.Metadata.TMDB
  alias Hivefin.Repo

  setup do
    Req.Test.verify_on_exit!()

    tmp =
      Path.join(System.tmp_dir!(), "hivefin-img-cache-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp)
    previous_dir = Application.get_env(:hivefin, :image_cache_dir)
    previous_req = Application.get_env(:hivefin, :metadata_req_options)

    Application.put_env(:hivefin, :image_cache_dir, tmp)

    Application.put_env(:hivefin, :metadata_req_options,
      plug: {Req.Test, TMDB},
      retry: false
    )

    on_exit(fn ->
      Application.put_env(:hivefin, :image_cache_dir, previous_dir)
      Application.put_env(:hivefin, :metadata_req_options, previous_req)
      File.rm_rf(tmp)
    end)

    {:ok, library} =
      LibraryContext.create_library(%{
        name: "Movies",
        type: :movies,
        path: Path.expand("test/support/fixtures/media_tree/movies", File.cwd!())
      })

    {:ok, item, :created} =
      LibraryContext.find_or_create_movie(library.id, %{name: "Test Movie", production_year: 2020})

    %{item: item, cache_dir: tmp}
  end

  test "store downloads to cache dir and path_for resolves", %{item: item, cache_dir: dir} do
    body = "fake-image-bytes"

    Req.Test.stub(TMDB, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("image/jpeg")
      |> Plug.Conn.send_resp(200, body)
    end)

    assert {:ok, path} =
             ImageCache.store(item.id, :primary, "https://image.tmdb.org/t/p/w500/x.jpg")

    assert String.starts_with?(path, dir)
    assert File.read!(path) == body
    assert {:ok, ^path} = ImageCache.path_for(item.id, :primary)
    assert {:ok, ^path} = ImageCache.path_for(item.id, "Primary")

    tags = ImageCache.image_tags_for(item.id)
    assert is_binary(tags["Primary"])
  end

  test "path_for returns :error when missing", %{item: item} do
    assert :error = ImageCache.path_for(item.id, :backdrop)
  end

  test "store rejects invalid type", %{item: item} do
    assert {:error, :invalid_args} =
             ImageCache.store(item.id, :thumb, "https://example.com/x.jpg")
  end

  test "store skips the download when the image is already cached on disk", %{
    item: item,
    cache_dir: dir
  } do
    # No Req.Test.stub configured for this test's TMDB plug: a stub with no
    # match clause makes Req.Test raise, so any HTTP attempt fails the test
    # loudly instead of silently passing.
    path = Path.join([dir, item.id, "primary.jpg"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "already-cached-bytes")

    {:ok, _image} =
      %Image{}
      |> Image.changeset(%{item_id: item.id, type: :primary, local_path: path, provider: "tmdb"})
      |> Repo.insert()

    assert {:ok, ^path} =
             ImageCache.store(item.id, :primary, "https://image.tmdb.org/t/p/w500/x.jpg")

    assert File.read!(path) == "already-cached-bytes"
  end

  test "store_person skips the download when the image is already cached on disk", %{
    cache_dir: dir
  } do
    # No Req.Test.stub configured for this test's TMDB plug: a stub with no
    # match clause makes Req.Test raise, so any HTTP attempt fails the test
    # loudly instead of silently passing.
    {:ok, person} =
      %Hivefin.Library.Person{}
      |> Hivefin.Library.Person.changeset(%{name: "Glenn Close"})
      |> Repo.insert()

    path = Path.join([dir, person.id, "primary.jpg"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "already-cached-bytes")

    {:ok, _image} =
      %Image{}
      |> Image.changeset(%{
        person_id: person.id,
        type: :primary,
        local_path: path,
        provider: "tmdb"
      })
      |> Repo.insert()

    assert {:ok, ^path} =
             ImageCache.store_person(person.id, "https://image.tmdb.org/t/p/w185/x.jpg")

    assert File.read!(path) == "already-cached-bytes"
  end

  test "store_person marks a confirmed failure and never retries it", %{cache_dir: dir} do
    {:ok, person} =
      %Hivefin.Library.Person{}
      |> Hivefin.Library.Person.changeset(%{name: "Nobody's Seen This Photo"})
      |> Repo.insert()

    Req.Test.stub(TMDB, fn conn ->
      conn |> Plug.Conn.put_status(404) |> Plug.Conn.send_resp(404, "")
    end)

    url = "https://image.tmdb.org/t/p/w185/gone.jpg"
    assert {:error, {:http_error, 404}} = ImageCache.store_person(person.id, url)

    # Persisted as a "don't retry" marker: local_path nil, not a missing row.
    image = Repo.get_by(Image, person_id: person.id, type: :primary)
    assert image
    assert is_nil(image.local_path)
    refute File.exists?(Path.join([dir, person.id]))

    # No second Req.Test.stub configured: a stub with no match clause raises
    # if this attempts a second HTTP call — it must not.
    assert {:error, :no_photo} = ImageCache.store_person(person.id, url)
  end

  test "store re-downloads when the cached row's file is missing from disk", %{
    item: item,
    cache_dir: dir
  } do
    body = "freshly-downloaded-bytes"

    Req.Test.stub(TMDB, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("image/jpeg")
      |> Plug.Conn.send_resp(200, body)
    end)

    stale_path = Path.join([dir, item.id, "primary.jpg"])

    {:ok, _image} =
      %Image{}
      |> Image.changeset(%{
        item_id: item.id,
        type: :primary,
        local_path: stale_path,
        provider: "tmdb"
      })
      |> Repo.insert()

    refute File.exists?(stale_path)

    assert {:ok, path} =
             ImageCache.store(item.id, :primary, "https://image.tmdb.org/t/p/w500/x.jpg")

    assert File.read!(path) == body
  end
end
