defmodule Hivefin.Metadata.ImageCacheTest do
  use Hivefin.DataCase, async: false

  import Ecto.Query

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

  test "a concurrent winner's row and file survive a losing store_person/2 call", %{
    cache_dir: dir
  } do
    # A genuine two-connection race, not a simulated one: the "winner" (a
    # separate Task on its own real, non-sandboxed connection) holds an
    # open, uncommitted transaction with the row already inserted. That
    # makes OUR OWN conflicting insert (issued below, by this test's normal
    # connection via store_person/2) genuinely BLOCK in Postgres — not fail
    # immediately — until the winner commits. That block is what makes this
    # deterministic instead of depending on scheduling luck, and it's what
    # reproduces the exact window the bug lived in: our own cache-miss check
    # sees nothing, then our own insert discovers a row we didn't know about.
    #
    # Everything the winner touches (person + its committed Image row) must
    # be real, committed rows for its separate connection to see them as
    # valid — hence checkout(sandbox: false) confined to the winner Task
    # (and to on_exit's cleanup), never to this test's own main process, so
    # Hivefin.DataCase's own sandbox/owner lifecycle is left alone.
    body = "shared-photo-bytes"
    test_pid = self()

    winner =
      Task.async(fn ->
        :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)

        {:ok, person} =
          %Hivefin.Library.Person{}
          |> Hivefin.Library.Person.changeset(%{name: "Race Person"})
          |> Repo.insert()

        path = Path.join([dir, person.id, "primary.jpg"])
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, body)

        Repo.transaction(fn ->
          {:ok, _} =
            %Image{}
            |> Image.changeset(%{
              person_id: person.id,
              type: :primary,
              local_path: path,
              provider: "tmdb"
            })
            |> Repo.insert()

          send(test_pid, {:winner_ready, person.id, path})
          # Holds the row open long enough for the loser's own conflicting
          # insert (issued by the main test process, below) to reach
          # Postgres and start blocking on it. Short and bounded: this is a
          # real, briefly-globally-visible commit (see the module note on
          # sandbox: false), so the shorter this window, the less chance of
          # colliding with an unrelated broad query in another test.
          Process.sleep(50)
        end)

        Ecto.Adapters.SQL.Sandbox.checkin(Repo)
      end)

    {person_id, path} =
      receive do
        {:winner_ready, id, p} -> {id, p}
      after
        1000 -> flunk("winner never signaled readiness")
      end

    on_exit(fn ->
      cleanup =
        Task.async(fn ->
          :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)
          Repo.delete_all(from(i in Image, where: i.person_id == ^person_id))
          Repo.delete_all(from(p in Hivefin.Library.Person, where: p.id == ^person_id))
          Ecto.Adapters.SQL.Sandbox.checkin(Repo)
        end)

      Task.await(cleanup, 5000)
    end)

    Req.Test.stub(TMDB, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("image/jpeg")
      |> Plug.Conn.send_resp(200, body)
    end)

    url = "https://image.tmdb.org/t/p/w185/race.jpg"
    assert {:ok, ^path} = ImageCache.store_person(person_id, url)

    Task.await(winner, 5000)

    images = Repo.all(from(i in Image, where: i.person_id == ^person_id))
    assert length(images) == 1
    assert [%Image{local_path: ^path}] = images
    refute is_nil(hd(images).local_path)
    assert File.regular?(path)
    assert File.read!(path) == body
  end

  test "a transient failure marks nothing and the next call retries", %{cache_dir: _dir} do
    {:ok, person} =
      %Hivefin.Library.Person{}
      |> Hivefin.Library.Person.changeset(%{name: "Transient Failure Person"})
      |> Repo.insert()

    url = "https://image.tmdb.org/t/p/w185/flaky.jpg"

    Req.Test.stub(TMDB, fn conn ->
      conn |> Plug.Conn.put_status(500) |> Plug.Conn.send_resp(500, "")
    end)

    assert {:error, {:http_error, 500}} = ImageCache.store_person(person.id, url)
    refute Repo.get_by(Image, person_id: person.id, type: :primary)

    # A subsequent call must be a genuine retry, not a no-op against a
    # marker — a working stub this time succeeds normally.
    body = "recovered-bytes"

    Req.Test.stub(TMDB, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("image/jpeg")
      |> Plug.Conn.send_resp(200, body)
    end)

    assert {:ok, path} = ImageCache.store_person(person.id, url)
    assert File.read!(path) == body
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
