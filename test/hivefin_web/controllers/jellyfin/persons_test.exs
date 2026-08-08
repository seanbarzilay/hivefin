defmodule HivefinWeb.Jellyfin.PersonsTest do
  use HivefinWeb.ConnCase, async: true

  alias Hivefin.Library.{Item, LibraryContext, PeopleContext}
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

    {:ok, _} =
      PeopleContext.replace_for_item(item.id, [
        %{
          tmdb_id: 3084,
          name: "Glenn Close",
          role: "Cruella De Vil",
          type: "Actor",
          sort_order: 0,
          profile_path: nil
        },
        %{
          tmdb_id: 1,
          name: "Kevin Lima",
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

    {:ok, conn: conn, item: item}
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

  test "GET /Persons filters by SearchTerm", %{conn: conn} do
    body = json_response(get(conn, "/Persons?SearchTerm=glenn"), 200)

    assert length(body["Items"]) == 1
    assert hd(body["Items"])["Name"] == "Glenn Close"
  end

  test "GET /Persons/:name returns one person by NAME", %{conn: conn} do
    body = json_response(get(conn, "/Persons/Glenn%20Close"), 200)

    assert body["Name"] == "Glenn Close"
    assert body["Type"] == "Person"
    assert body["Id"]
  end

  test "GET /Persons/:name handles punctuation and non-ASCII characters in the name", %{
    conn: conn,
    item: item
  } do
    {:ok, _} =
      PeopleContext.replace_for_item(item.id, [
        %{
          tmdb_id: 555,
          name: "J.J. Abrams",
          role: "",
          type: "Director",
          sort_order: nil,
          profile_path: nil
        },
        %{
          tmdb_id: 556,
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
end
