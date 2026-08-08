defmodule Hivefin.Library.PeopleContextTest do
  use Hivefin.DataCase, async: true

  import Ecto.Query

  alias Hivefin.Library.{Item, ItemPerson, LibraryContext, PeopleContext, Person}
  alias Hivefin.Repo

  defp make_item(name) do
    path = Path.join(System.tmp_dir!(), "pc-#{System.unique_integer([:positive])}")
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
        name: name,
        type: :movie,
        sort_name: String.downcase(name),
        library_id: library.id
      })
      |> Repo.insert()

    item
  end

  defp people do
    [
      %{
        tmdb_id: 3084,
        name: "Glenn Close",
        role: "Cruella De Vil",
        type: "Actor",
        sort_order: 0,
        profile_path: "/c.jpg"
      },
      %{
        tmdb_id: 1,
        name: "Kevin Lima",
        role: "",
        type: "Director",
        sort_order: nil,
        profile_path: nil
      }
    ]
  end

  test "writes people and links for an item" do
    item = make_item("102 Dalmatians")

    assert {:ok, 2} = PeopleContext.replace_for_item(item.id, people())

    listed = PeopleContext.list_for_item(item.id)
    assert length(listed) == 2
    assert %{role: "Cruella De Vil", type: "Actor"} = hd(listed)
    assert hd(listed).person.name == "Glenn Close"
  end

  test "the same TMDb person across two items is ONE people row" do
    a = make_item("102 Dalmatians")
    b = make_item("101 Dalmatians")

    assert {:ok, 2} = PeopleContext.replace_for_item(a.id, people())
    assert {:ok, 2} = PeopleContext.replace_for_item(b.id, people())

    assert Repo.aggregate(Person, :count) == 2
    assert length(PeopleContext.list_for_item(a.id)) == 2
    assert length(PeopleContext.list_for_item(b.id)) == 2
  end

  test "re-ingest replaces links rather than duplicating them" do
    item = make_item("102 Dalmatians")
    assert {:ok, 2} = PeopleContext.replace_for_item(item.id, people())
    assert {:ok, 2} = PeopleContext.replace_for_item(item.id, people())

    assert length(PeopleContext.list_for_item(item.id)) == 2
  end

  test "re-ingest drops people who are no longer credited" do
    item = make_item("102 Dalmatians")
    assert {:ok, 2} = PeopleContext.replace_for_item(item.id, people())

    corrected = [hd(people())]
    assert {:ok, 1} = PeopleContext.replace_for_item(item.id, corrected)

    names = Enum.map(PeopleContext.list_for_item(item.id), & &1.person.name)
    assert names == ["Glenn Close"]
  end

  test "replace_for_item with an empty list leaves existing rows intact" do
    item = make_item("102 Dalmatians")
    assert {:ok, 2} = PeopleContext.replace_for_item(item.id, people())

    assert {:ok, 0} = PeopleContext.replace_for_item(item.id, [])

    assert length(PeopleContext.list_for_item(item.id)) == 2
  end

  test "cast sorts before crew" do
    item = make_item("102 Dalmatians")
    # Deliberately crew-first input; ordering must come from the query.
    assert {:ok, 2} = PeopleContext.replace_for_item(item.id, Enum.reverse(people()))

    assert Enum.map(PeopleContext.list_for_item(item.id), & &1.type) == ["Actor", "Director"]
  end

  test "crew role persists as an empty string, never SQL NULL" do
    item = make_item("102 Dalmatians")
    assert {:ok, 2} = PeopleContext.replace_for_item(item.id, people())

    crew = Enum.find(PeopleContext.list_for_item(item.id), &(&1.type == "Director"))
    assert crew.role == ""

    # Read the persisted column directly — bypass any struct default that
    # could paper over a silently-nilified value.
    db_role =
      Repo.one!(
        from(ip in ItemPerson,
          where: ip.item_id == ^item.id and ip.type == "Director",
          select: ip.role
        )
      )

    assert db_role == ""
    refute is_nil(db_role)
  end

  test "profile_path is persisted on the person row when present" do
    item = make_item("102 Dalmatians")
    assert {:ok, 2} = PeopleContext.replace_for_item(item.id, people())

    glenn = Enum.find(PeopleContext.list_for_item(item.id), &(&1.person.name == "Glenn Close"))
    assert glenn.person.profile_path == "/c.jpg"

    kevin = Enum.find(PeopleContext.list_for_item(item.id), &(&1.person.name == "Kevin Lima"))
    assert is_nil(kevin.person.profile_path)
  end

  test "re-ingest backfills profile_path on a person row that had none (cached-match re-apply)" do
    item = make_item("102 Dalmatians")

    # Simulates a person row from before this column existed, or from a
    # payload where TMDb had no photo for them yet.
    stale = [%{hd(people()) | profile_path: nil}, Enum.at(people(), 1)]
    assert {:ok, 2} = PeopleContext.replace_for_item(item.id, stale)

    glenn = Enum.find(PeopleContext.list_for_item(item.id), &(&1.person.name == "Glenn Close"))
    assert is_nil(glenn.person.profile_path)

    # Re-applying the same match — as a backfill re-running refresh against
    # the TMDb response cache does, with no new API call — must populate the
    # now-present profile_path on the existing row rather than leaving it nil.
    assert {:ok, 2} = PeopleContext.replace_for_item(item.id, people())

    glenn = Enum.find(PeopleContext.list_for_item(item.id), &(&1.person.name == "Glenn Close"))
    assert glenn.person.profile_path == "/c.jpg"
  end

  test "re-ingest follows TMDb when it changes a person's photo" do
    item = make_item("102 Dalmatians")
    assert {:ok, 2} = PeopleContext.replace_for_item(item.id, people())

    changed = [%{hd(people()) | profile_path: "/new-photo.jpg"}, Enum.at(people(), 1)]
    assert {:ok, 2} = PeopleContext.replace_for_item(item.id, changed)

    glenn = Enum.find(PeopleContext.list_for_item(item.id), &(&1.person.name == "Glenn Close"))
    assert glenn.person.profile_path == "/new-photo.jpg"
  end

  test "two crew jobs collapsing to the same type and role insert without raising" do
    item = make_item("102 Dalmatians")

    # e.g. one writer credited for both "Story" and "Screenplay": TMDB maps
    # both jobs to type: "Writer", role: "" — same person, same type, same
    # role, from two distinct source rows.
    credits = [
      %{
        tmdb_id: 42,
        name: "Story Writer",
        role: "",
        type: "Writer",
        sort_order: nil,
        profile_path: nil
      },
      %{
        tmdb_id: 42,
        name: "Story Writer",
        role: "",
        type: "Writer",
        sort_order: nil,
        profile_path: nil
      }
    ]

    assert {:ok, 1} = PeopleContext.replace_for_item(item.id, credits)
    assert length(PeopleContext.list_for_item(item.id)) == 1
  end
end
