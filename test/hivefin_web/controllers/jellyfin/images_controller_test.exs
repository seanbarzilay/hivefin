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
    # A confirmed miss, and the strongest kind: the server knows there is no
    # photo without asking TMDb at all, and that stays true until a refresh
    # sets a profile_path — the same event that clears a 404 marker. Same
    # classification, therefore the same long cache-control.
    assert get_resp_header(conn, "cache-control") == ["public, max-age=3600"]
  end

  test "a transient TMDb failure 404s WITHOUT the long cache-control", %{conn: conn} do
    entry = person_with_photo(47, "Flaky Photo Person", "/flaky.jpg")

    Req.Test.stub(TMDB, fn tmdb_conn ->
      tmdb_conn |> Plug.Conn.put_status(500) |> Plug.Conn.send_resp(500, "")
    end)

    conn = get(conn, ~p"/Items/#{entry.person.id}/Images/Primary")
    assert conn.status == 404

    # The server marked nothing and will retry on the very next request
    # (asserted below). Telling the browser this face is absent for an hour
    # would defeat exactly that retry.
    refute get_resp_header(conn, "cache-control") == ["public, max-age=3600"]
    assert get_resp_header(conn, "cache-control") == ["no-store"]

    # And the retry really is available immediately: a working stub succeeds.
    Req.Test.stub(TMDB, fn tmdb_conn ->
      tmdb_conn
      |> Plug.Conn.put_resp_content_type("image/jpeg")
      |> Plug.Conn.send_resp(200, "recovered-bytes")
    end)

    conn2 = get(build_conn(), "/Items/#{entry.person.id}/Images/Primary")
    assert conn2.status == 200
    assert conn2.resp_body == "recovered-bytes"
  end

  test "a rate-limit rejection 404s WITHOUT the long cache-control", %{conn: conn} do
    entry = person_with_photo(48, "Rate Limited Person", "/limited.jpg")
    force_rate_limiter_rejection()

    # No Req.Test.stub configured: the rate limiter must fail closed before
    # any HTTP attempt, so reaching TMDb here would raise instead of 404ing.
    conn = get(conn, ~p"/Items/#{entry.person.id}/Images/Primary")

    assert conn.status == 404
    refute get_resp_header(conn, "cache-control") == ["public, max-age=3600"]
    assert get_resp_header(conn, "cache-control") == ["no-store"]

    # Nothing was persisted, so the next request is a genuine retry.
    refute Repo.get_by(Image, person_id: entry.person.id, type: :primary)
  end

  test "GET Primary for a confirmed-failed headshot 404s with cache-control and is never retried",
       %{conn: conn} do
    lib_path = Path.join(System.tmp_dir!(), "img-ctrl-#{System.unique_integer([:positive])}")
    File.mkdir_p!(lib_path)
    on_exit(fn -> File.rm_rf(lib_path) end)

    {:ok, library} =
      LibraryContext.create_library(%{name: "Gone", type: :movies, path: lib_path})

    {:ok, movie, :created} =
      LibraryContext.find_or_create_movie(library.id, %{name: "Gone Photo", production_year: 2020})

    assert {:ok, 1} =
             PeopleContext.replace_for_item(movie.id, [
               %{
                 tmdb_id: 44,
                 name: "Removed Photo Person",
                 role: "",
                 type: "Actor",
                 sort_order: 0,
                 profile_path: "/removed.jpg"
               }
             ])

    [entry] = PeopleContext.list_for_item(movie.id)

    Req.Test.stub(TMDB, fn tmdb_conn ->
      tmdb_conn |> Plug.Conn.put_status(404) |> Plug.Conn.send_resp(404, "")
    end)

    conn = get(conn, ~p"/Items/#{entry.person.id}/Images/Primary")
    assert conn.status == 404
    assert get_resp_header(conn, "cache-control") == ["public, max-age=3600"]

    # No second Req.Test.stub is configured: any second HTTP attempt raises,
    # proving the unauthenticated route can't re-burn the shared TMDb budget
    # on every subsequent view of the same movie.
    conn2 = get(build_conn(), "/Items/#{entry.person.id}/Images/Primary")
    assert conn2.status == 404
    assert get_resp_header(conn2, "cache-control") == ["public, max-age=3600"]
  end

  test "the concurrency cap 404s immediately instead of queueing on the rate limiter", %{
    conn: conn
  } do
    lib_path = Path.join(System.tmp_dir!(), "img-ctrl-#{System.unique_integer([:positive])}")
    File.mkdir_p!(lib_path)
    on_exit(fn -> File.rm_rf(lib_path) end)

    {:ok, library} =
      LibraryContext.create_library(%{name: "Capped", type: :movies, path: lib_path})

    {:ok, movie, :created} =
      LibraryContext.find_or_create_movie(library.id, %{
        name: "Capped Photo",
        production_year: 2020
      })

    assert {:ok, 1} =
             PeopleContext.replace_for_item(movie.id, [
               %{
                 tmdb_id: 45,
                 name: "Queued Out Person",
                 role: "",
                 type: "Actor",
                 sort_order: 0,
                 profile_path: "/queued.jpg"
               }
             ])

    [entry] = PeopleContext.list_for_item(movie.id)

    # Saturate the exact gate ImagesController checks out of, without going
    # through 10 real requests.
    gate_key = {HivefinWeb.Jellyfin.ImagesController, :headshot_fetch_gate}
    ref = :counters.new(1, [])
    :counters.add(ref, 1, 10)
    :persistent_term.put(gate_key, ref)
    on_exit(fn -> :persistent_term.erase(gate_key) end)

    # No Req.Test.stub configured: if the cap failed to short-circuit before
    # any TMDb call, this would raise instead of silently 404ing.
    {elapsed_us, conn} =
      :timer.tc(fn -> get(conn, ~p"/Items/#{entry.person.id}/Images/Primary") end)

    assert conn.status == 404
    # Nowhere near RateLimiter.checkout/1's 120s call timeout — this must
    # fail fast, not queue.
    assert elapsed_us < 1_000_000
    # A cap rejection says nothing about whether the photo exists — the next
    # view, once the burst clears, must be allowed to try again.
    refute get_resp_header(conn, "cache-control") == ["public, max-age=3600"]
  end

  test "a changed profile_path is a genuine cache miss and fetches the new photo", %{conn: conn} do
    lib_path = Path.join(System.tmp_dir!(), "img-ctrl-#{System.unique_integer([:positive])}")
    File.mkdir_p!(lib_path)
    on_exit(fn -> File.rm_rf(lib_path) end)

    {:ok, library} =
      LibraryContext.create_library(%{name: "Changed", type: :movies, path: lib_path})

    {:ok, movie, :created} =
      LibraryContext.find_or_create_movie(library.id, %{
        name: "Changed Photo",
        production_year: 2020
      })

    assert {:ok, 1} =
             PeopleContext.replace_for_item(movie.id, [
               %{
                 tmdb_id: 46,
                 name: "Recast Photo Person",
                 role: "",
                 type: "Actor",
                 sort_order: 0,
                 profile_path: "/old.jpg"
               }
             ])

    [entry] = PeopleContext.list_for_item(movie.id)

    Req.Test.stub(TMDB, fn tmdb_conn ->
      assert tmdb_conn.request_path =~ "/old.jpg"

      tmdb_conn
      |> Plug.Conn.put_resp_content_type("image/jpeg")
      |> Plug.Conn.send_resp(200, "old-photo-bytes")
    end)

    conn = get(conn, ~p"/Items/#{entry.person.id}/Images/Primary")
    assert conn.status == 200
    assert conn.resp_body == "old-photo-bytes"

    # A legitimate metadata refresh changes the photo TMDb has for them.
    assert {:ok, 1} =
             PeopleContext.replace_for_item(movie.id, [
               %{
                 tmdb_id: 46,
                 name: "Recast Photo Person",
                 role: "",
                 type: "Actor",
                 sort_order: 0,
                 profile_path: "/new.jpg"
               }
             ])

    Req.Test.stub(TMDB, fn tmdb_conn ->
      assert tmdb_conn.request_path =~ "/new.jpg"

      tmdb_conn
      |> Plug.Conn.put_resp_content_type("image/jpeg")
      |> Plug.Conn.send_resp(200, "new-photo-bytes")
    end)

    conn2 = get(build_conn(), "/Items/#{entry.person.id}/Images/Primary")
    assert conn2.status == 200
    assert conn2.resp_body == "new-photo-bytes"
  end

  defp person_with_photo(tmdb_id, name, profile_path) do
    lib_path = Path.join(System.tmp_dir!(), "img-ctrl-#{System.unique_integer([:positive])}")
    File.mkdir_p!(lib_path)
    on_exit(fn -> File.rm_rf(lib_path) end)

    {:ok, library} = LibraryContext.create_library(%{name: name, type: :movies, path: lib_path})

    {:ok, movie, :created} =
      LibraryContext.find_or_create_movie(library.id, %{name: name, production_year: 2020})

    assert {:ok, 1} =
             PeopleContext.replace_for_item(movie.id, [
               %{
                 tmdb_id: tmdb_id,
                 name: name,
                 role: "",
                 type: "Actor",
                 sort_order: 0,
                 profile_path: profile_path
               }
             ])

    [entry] = PeopleContext.list_for_item(movie.id)
    entry
  end

  # Drives RateLimiter.checkout/0 down its fail-closed `:error` branch by
  # swapping the named limiter for a process that dies without replying —
  # same observable outcome as a real exhaustion, without waiting out the
  # limiter's 120s call timeout. Safe here: this file is async: false, so it
  # runs in ExUnit's serial phase with no other test in flight.
  defp force_rate_limiter_rejection do
    limiter = Hivefin.Metadata.RateLimiter
    real = Process.whereis(limiter)
    if is_pid(real), do: Process.unregister(limiter)

    stub =
      spawn(fn ->
        receive do
          _ -> exit(:rate_limited)
        end
      end)

    Process.register(stub, limiter)

    on_exit(fn ->
      if Process.whereis(limiter) == stub, do: Process.unregister(limiter)
      if is_pid(real) and Process.alive?(real), do: Process.register(real, limiter)
    end)
  end
end
