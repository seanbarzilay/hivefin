defmodule Hivefin.Library.PeopleContextTest do
  use Hivefin.DataCase, async: true

  alias Hivefin.Library.{Item, LibraryContext, PeopleContext, Person}
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

  test "an empty credits list clears the item's people" do
    item = make_item("102 Dalmatians")
    assert {:ok, 2} = PeopleContext.replace_for_item(item.id, people())
    assert {:ok, 0} = PeopleContext.replace_for_item(item.id, [])

    assert PeopleContext.list_for_item(item.id) == []
  end

  test "cast sorts before crew" do
    item = make_item("102 Dalmatians")
    # Deliberately crew-first input; ordering must come from the query.
    assert {:ok, 2} = PeopleContext.replace_for_item(item.id, Enum.reverse(people()))

    assert Enum.map(PeopleContext.list_for_item(item.id), & &1.type) == ["Actor", "Director"]
  end
end
