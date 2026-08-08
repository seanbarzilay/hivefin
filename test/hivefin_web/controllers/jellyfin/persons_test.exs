defmodule HivefinWeb.Jellyfin.PersonsTest do
  use HivefinWeb.ConnCase, async: true

  alias Hivefin.Library.{Item, LibraryContext, PeopleContext, Person}
  alias Hivefin.Repo

  setup do
    {:ok, user} =
      Hivefin.Accounts.create_user(%{
        name: "P",
        username: "personsuser",
        password: "password1",
        admin: true
      })

    {:ok, token, _} =
      Hivefin.Accounts.issue_token(user, %{
        device_id: "d",
        device_name: "D",
        client: "Jellyfin Web",
        client_version: "10.10.7"
      })

    # Library.changeset validates the path is an existing directory (see
    # PeopleContextTest's make_item/1 for the same pattern) — must exist
    # before create_library/1 is called, not just be a plausible-looking path.
    path = Path.join(System.tmp_dir!(), "persons-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf(path) end)

    {:ok, library} =
      LibraryContext.create_library(%{
        name: "M-#{System.unique_integer([:positive])}",
        type: :movies,
        path: path
      })

    {:ok, item} =
      %Item{}
      |> Item.changeset(%{
        name: "102 Dalmatians",
        type: :movie,
        sort_name: "102",
        library_id: library.id
      })
      |> Repo.insert()

    # Deliberately NOT the tmdb_id: 3084/"Glenn Close" + tmdb_id: 1/"Kevin
    # Lima" pair five other test files already hardcode — reusing it here
    # raised the odds of hitting PeopleContext.upsert_person/1's concurrent
    # insert path for the exact same two rows across files running async.
    # A fresh unique_integer per test run means this file never contends
    # with (or with itself, across its own async tests) any other consumer.
    tmdb_base = System.unique_integer([:positive])
    actor_name = "Persons Test Actor #{tmdb_base}"
    director_name = "Persons Test Director #{tmdb_base + 1}"

    {:ok, _} =
      PeopleContext.replace_for_item(item.id, [
        %{
          tmdb_id: tmdb_base,
          name: actor_name,
          role: "Lead",
          type: "Actor",
          sort_order: 0,
          profile_path: nil
        },
        %{
          tmdb_id: tmdb_base + 1,
          name: director_name,
          role: "",
          type: "Director",
          sort_order: nil,
          profile_path: nil
        }
      ])

    conn =
      build_conn()
      |> put_req_header(
        "x-emby-authorization",
        ~s(MediaBrowser Client="Jellyfin Web", Device="D", DeviceId="d", Version="10.10.7", Token="#{token}")
      )

    {:ok,
     conn: conn,
     user: user,
     library: library,
     item: item,
     tmdb_base: tmdb_base,
     actor_name: actor_name,
     director_name: director_name}
  end

  test "GET /Persons returns a query result", %{conn: conn} do
    body = json_response(get(conn, "/Persons"), 200)

    assert is_list(body["Items"])
    assert body["Items"] != []
    assert body["TotalRecordCount"] == 2
    assert body["StartIndex"] == 0
    assert Enum.all?(body["Items"], &(&1["Type"] == "Person"))
  end

  test "GET /Persons honours Limit and StartIndex", %{conn: conn} do
    body = json_response(get(conn, "/Persons?Limit=1&StartIndex=1"), 200)

    assert length(body["Items"]) == 1
    assert body["TotalRecordCount"] == 2
    assert body["StartIndex"] == 1
  end

  test "GET /Persons treats a negative Limit as zero instead of raising", %{conn: conn} do
    # Postgres raises "LIMIT must not be negative" rather than tolerating
    # one — this must come back as a normal (if empty) page, never a 500.
    body = json_response(get(conn, "/Persons?Limit=-1"), 200)

    assert body["Items"] == []
    # The total is independent of the (clamped-to-zero) page size.
    assert body["TotalRecordCount"] == 2
  end

  test "GET /Persons treats a negative StartIndex as zero instead of raising", %{conn: conn} do
    # Postgres raises "OFFSET must not be negative" rather than tolerating
    # one — a negative StartIndex must behave like 0, not 500.
    body = json_response(get(conn, "/Persons?StartIndex=-5"), 200)

    assert body["StartIndex"] == 0
    assert length(body["Items"]) == 2
  end

  test "GET /Persons filters by SearchTerm", %{
    conn: conn,
    tmdb_base: tmdb_base,
    actor_name: actor_name
  } do
    # tmdb_base appears only in the actor's name (the director's is
    # tmdb_base + 1), so this can only ever match the one row.
    body = json_response(get(conn, "/Persons?SearchTerm=#{tmdb_base}"), 200)

    assert length(body["Items"]) == 1
    assert hd(body["Items"])["Name"] == actor_name
  end

  test "GET /Persons/:name returns one person by NAME", %{conn: conn, actor_name: actor_name} do
    body = json_response(get(conn, "/Persons/" <> URI.encode(actor_name)), 200)

    assert body["Name"] == actor_name
    assert body["Type"] == "Person"
    assert body["Id"]
  end

  test "GET /Persons/:name handles punctuation and non-ASCII characters in the name", %{
    conn: conn,
    item: item,
    tmdb_base: tmdb_base
  } do
    {:ok, _} =
      PeopleContext.replace_for_item(item.id, [
        %{
          tmdb_id: tmdb_base + 2,
          name: "J.J. Abrams",
          role: "",
          type: "Director",
          sort_order: nil,
          profile_path: nil
        },
        %{
          tmdb_id: tmdb_base + 3,
          name: "Penélope Cruz",
          role: "Herself",
          type: "Actor",
          sort_order: 1,
          profile_path: nil
        }
      ])

    body1 = json_response(get(conn, "/Persons/" <> URI.encode("J.J. Abrams")), 200)
    assert body1["Name"] == "J.J. Abrams"

    body2 = json_response(get(conn, "/Persons/" <> URI.encode("Penélope Cruz")), 200)
    assert body2["Name"] == "Penélope Cruz"
  end

  test "GET /Persons/:name 404s as JSON for an unknown name", %{conn: conn} do
    conn = get(conn, "/Persons/Nobody%20At%20All")

    assert conn.status == 404
    refute response(conn, 404) =~ "<", "must be JSON, not SPA HTML"
  end

  test "GET /Persons requires authentication" do
    assert json_response(get(build_conn(), "/Persons"), 401)
  end

  # The request jellyfin-web 10.10.7 ACTUALLY makes when a cast member is
  # clicked. renderCast builds `#/details?id=<personId>` (appRouter's
  # itemTypes list contains "Person"), and itemDetails' getPromise turns that
  # into apiClient.getItem(userId, id) — GET /Users/{uid}/Items/{personId},
  # no Fields param. /Persons/{name} is never called by this client.
  describe "GET /Users/:user_id/Items/:person_id (the cast-click route)" do
    test "returns a Person DTO with no Fields param", %{
      conn: conn,
      user: user,
      actor_name: actor_name
    } do
      person_id = person_id_from_listing(conn, actor_name)

      body = json_response(get(conn, "/Users/#{user.id}/Items/#{person_id}"), 200)

      assert body["Type"] == "Person"
      assert body["Name"] == actor_name
      assert body["Id"] == person_id
    end

    test "carries MovieCount matching the number of films the person is credited in", %{
      conn: conn,
      user: user,
      library: library,
      tmdb_base: tmdb_base,
      actor_name: actor_name
    } do
      # Same tmdb_id ⇒ same person row, now credited on a second film.
      {:ok, second} =
        %Item{}
        |> Item.changeset(%{
          name: "101 Dalmatians",
          type: :movie,
          sort_name: "101",
          library_id: library.id
        })
        |> Repo.insert()

      {:ok, _} =
        PeopleContext.replace_for_item(second.id, [
          %{
            tmdb_id: tmdb_base,
            name: actor_name,
            role: "Lead",
            type: "Actor",
            sort_order: 0,
            profile_path: nil
          },
          # Credited twice on the same film: two item_people rows, one movie.
          %{
            tmdb_id: tmdb_base,
            name: actor_name,
            role: "",
            type: "Director",
            sort_order: nil,
            profile_path: nil
          }
        ])

      person_id = person_id_from_listing(conn, actor_name)
      body = json_response(get(conn, "/Users/#{user.id}/Items/#{person_id}"), 200)

      assert body["MovieCount"] == 2
      assert body["SeriesCount"] == 0
      assert body["EpisodeCount"] == 0
    end

    test "a person credited in nothing emits a falsy count, not a truthy one", %{
      conn: conn,
      user: user
    } do
      # jellyfin-web guards with `if (item.MovieCount)`, so 0 is correct and
      # falsy — the person page renders no "Movies" section, rather than an
      # empty one. What must never happen is a truthy value here.
      {:ok, uncredited} =
        %Person{}
        |> Person.changeset(%{name: "Uncredited #{System.unique_integer([:positive])}"})
        |> Repo.insert()

      body =
        json_response(
          get(conn, "/Users/#{user.id}/Items/#{Hivefin.Jellyfin.Id.format(uncredited.id)}"),
          200
        )

      assert body["Type"] == "Person"
      assert body["MovieCount"] == 0
      assert body["SeriesCount"] == 0
      assert body["EpisodeCount"] == 0
    end
  end

  test "GET /Persons?Filters=IsFavorite returns an empty page", %{conn: conn} do
    # jellyfin-web's Favorites tab fetches this for its "People" row and
    # un-hides the row if anything comes back. hivefin has no person
    # favorites, so it must come back empty.
    body = json_response(get(conn, "/Persons?Filters=IsFavorite&Limit=20"), 200)

    assert body["Items"] == []
    assert body["TotalRecordCount"] == 0
  end

  # Exactly how the client gets a person id: off a DTO, dashless, never
  # constructed test-side.
  defp person_id_from_listing(conn, name) do
    body = json_response(get(conn, "/Persons?SearchTerm=#{URI.encode(name)}"), 200)

    body["Items"] |> Enum.find(&(&1["Name"] == name)) |> Map.fetch!("Id")
  end
end
