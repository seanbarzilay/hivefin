defmodule HivefinWeb.Jellyfin.ItemsPersonFilterTest do
  use HivefinWeb.ConnCase, async: true

  alias Hivefin.Library.{Item, LibraryContext, PeopleContext}
  alias Hivefin.Repo

  setup do
    {:ok, user} =
      Hivefin.Accounts.create_user(%{
        name: "F",
        username: "filteruser",
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

    path = Path.join(System.tmp_dir!(), "filter-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf(path) end)

    {:ok, library} =
      LibraryContext.create_library(%{
        name: "M-#{System.unique_integer([:positive])}",
        type: :movies,
        path: path
      })

    insert = fn name ->
      {:ok, i} =
        %Item{}
        |> Item.changeset(%{
          name: name,
          type: :movie,
          sort_name: String.downcase(name),
          library_id: library.id
        })
        |> Repo.insert()

      i
    end

    with_close = insert.("102 Dalmatians")
    without = insert.("Some Other Film")

    {:ok, _} =
      PeopleContext.replace_for_item(with_close.id, [
        %{
          tmdb_id: 3084,
          name: "Glenn Close",
          role: "Cruella",
          type: "Actor",
          sort_order: 0,
          profile_path: nil
        }
      ])

    {:ok, _} =
      PeopleContext.replace_for_item(without.id, [
        %{
          tmdb_id: 999,
          name: "Someone Else",
          role: "Extra",
          type: "Actor",
          sort_order: 0,
          profile_path: nil
        }
      ])

    [entry] = PeopleContext.list_for_item(with_close.id)

    conn =
      build_conn()
      |> put_req_header(
        "x-emby-authorization",
        ~s(MediaBrowser Client="Jellyfin Web", Device="D", DeviceId="d", Version="10.10.7", Token="#{token}")
      )

    [
      conn: conn,
      person: entry.person,
      library: library,
      with_close: with_close,
      without: without
    ]
  end

  test "PersonIds filters to that person's items, using the DASHLESS id clients get",
       %{conn: conn, person: person, with_close: with_close} do
    dashless = Hivefin.Jellyfin.Id.format(person.id)
    refute dashless == person.id, "test must use the wire form, not the DB form"

    body = json_response(get(conn, "/Items?PersonIds=#{dashless}&Recursive=true"), 200)
    ids = Enum.map(body["Items"], & &1["Id"])

    assert Hivefin.Jellyfin.Id.format(with_close.id) in ids
    assert length(ids) == 1
    assert body["TotalRecordCount"] == 1
  end

  test "the dashed form works too", %{conn: conn, person: person, with_close: with_close} do
    body = json_response(get(conn, "/Items?PersonIds=#{person.id}&Recursive=true"), 200)

    assert Enum.map(body["Items"], & &1["Id"]) == [Hivefin.Jellyfin.Id.format(with_close.id)]
  end

  # Deliberate deviation from the brief's literal request shape: a bare
  # `/Items?Recursive=true` (no ParentId, no IncludeItemTypes) hits a
  # pre-existing, unrelated branch in LibraryContext.list_items_for_parent/2
  # that treats "no concrete type filter" as "browse libraries" regardless
  # of Recursive, and returns the 1 CollectionFolder instead of the 2 movies
  # — true on this branch before this task touched anything, and out of
  # scope to change here (see task-8-report.md). Scoping to the library via
  # ParentId exercises the actual thing this test is protecting: that
  # omitting PersonIds still returns every item the *item-level* query would
  # otherwise return, i.e. the new filter is opt-in, not a permanent narrowing.
  test "no PersonIds returns everything", %{conn: conn, library: library} do
    body =
      json_response(get(conn, "/Items?ParentId=#{library.id}&Recursive=true"), 200)

    assert length(body["Items"]) == 2
  end

  test "an unknown person id returns no items", %{conn: conn} do
    body =
      json_response(get(conn, "/Items?PersonIds=#{Ecto.UUID.generate()}&Recursive=true"), 200)

    assert body["Items"] == []
    assert body["TotalRecordCount"] == 0
  end

  test "a garbage (non-UUID) PersonIds value returns no items, not an error and not the whole library",
       %{conn: conn} do
    conn = get(conn, "/Items?PersonIds=not-a-real-id&Recursive=true")

    body = json_response(conn, 200)

    assert body["Items"] == []
    assert body["TotalRecordCount"] == 0
  end

  test "a comma-separated PersonIds list is OR: items for either person come back",
       %{conn: conn, person: person, with_close: with_close, without: without} do
    [other_entry] = PeopleContext.list_for_item(without.id)
    other_dashless = Hivefin.Jellyfin.Id.format(other_entry.person.id)
    this_dashless = Hivefin.Jellyfin.Id.format(person.id)

    body =
      json_response(
        get(conn, "/Items?PersonIds=#{this_dashless},#{other_dashless}&Recursive=true"),
        200
      )

    ids = Enum.map(body["Items"], & &1["Id"])

    assert Hivefin.Jellyfin.Id.format(with_close.id) in ids
    assert Hivefin.Jellyfin.Id.format(without.id) in ids
    assert length(ids) == 2
    assert body["TotalRecordCount"] == 2
  end

  test "a person credited twice on the same item (director AND writer) surfaces the item once, not twice",
       %{conn: conn, with_close: with_close} do
    {:ok, _} =
      PeopleContext.replace_for_item(with_close.id, [
        %{
          tmdb_id: 5000,
          name: "Multi Hyphenate",
          role: "",
          type: "Director",
          sort_order: nil,
          profile_path: nil
        },
        %{
          tmdb_id: 5000,
          name: "Multi Hyphenate",
          role: "",
          type: "Writer",
          sort_order: nil,
          profile_path: nil
        }
      ])

    credits =
      PeopleContext.list_for_item(with_close.id)
      |> Enum.filter(&(&1.person.name == "Multi Hyphenate"))

    assert length(credits) == 2, "setup must produce two item_people rows for one person"
    dashless = Hivefin.Jellyfin.Id.format(hd(credits).person.id)

    body = json_response(get(conn, "/Items?PersonIds=#{dashless}&Recursive=true"), 200)
    ids = Enum.map(body["Items"], & &1["Id"])

    assert ids == [Hivefin.Jellyfin.Id.format(with_close.id)]
    assert body["TotalRecordCount"] == 1
  end

  test "PersonIds composes with ParentId/IncludeItemTypes/paging, not replaces them",
       %{conn: conn, person: person, library: library, with_close: with_close} do
    dashless = Hivefin.Jellyfin.Id.format(person.id)

    body =
      json_response(
        get(
          conn,
          "/Items?PersonIds=#{dashless}&ParentId=#{library.id}&IncludeItemTypes=Movie&Recursive=true&Limit=10"
        ),
        200
      )

    assert Enum.map(body["Items"], & &1["Id"]) == [Hivefin.Jellyfin.Id.format(with_close.id)]

    # A ParentId for a different (empty) library must still narrow the result,
    # even though the person filter alone would match with_close.
    other_path =
      Path.join(System.tmp_dir!(), "filter-other-#{System.unique_integer([:positive])}")

    File.mkdir_p!(other_path)
    on_exit(fn -> File.rm_rf(other_path) end)

    {:ok, other_library} =
      LibraryContext.create_library(%{
        name: "Other-#{System.unique_integer([:positive])}",
        type: :movies,
        path: other_path
      })

    empty_body =
      json_response(
        get(conn, "/Items?PersonIds=#{dashless}&ParentId=#{other_library.id}&Recursive=true"),
        200
      )

    assert empty_body["Items"] == []
  end
end
