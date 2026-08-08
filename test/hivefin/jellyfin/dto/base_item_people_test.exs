defmodule Hivefin.Jellyfin.Dto.BaseItemPeopleTest do
  use Hivefin.DataCase, async: true

  alias Hivefin.Jellyfin.Dto.BaseItem
  alias Hivefin.Library.{Item, LibraryContext, PeopleContext}
  alias Hivefin.Repo

  # Listed literally, not read from the implementation — a test that derives
  # its expectations from the code under test agrees with a regression.
  @person_keys ~w(Id Name Role Type)

  setup do
    # create_library validates the path is an existing directory (see
    # PeopleContextTest's make_item/1 for the same pattern).
    path = Path.join(System.tmp_dir!(), "bip-#{System.unique_integer([:positive])}")
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

    {:ok, item: Repo.reload(item), library: library}
  end

  test "People is present when Fields asks for it", %{item: item} do
    dto = BaseItem.from_item(item, fields: ["People"])

    people = dto["People"]
    assert people != [], "expected cast and crew"
    assert length(people) == 2

    for p <- people, key <- @person_keys do
      assert Map.has_key?(p, key), "BaseItemPerson missing #{key}"
      refute is_nil(p[key]), "BaseItemPerson #{key} is null"
    end
  end

  test "crew Role is an empty string, never null", %{item: item} do
    # jellyfin-web may call .length/.trim on Role.
    dto = BaseItem.from_item(item, fields: ["People"])
    director = Enum.find(dto["People"], &(&1["Type"] == "Director"))

    assert director["Role"] == ""
  end

  test "People is ABSENT without the Fields flag", %{item: item} do
    # Deliberately unlike MediaSources, which rides along on every playable
    # item — that would put a full cast list on every movie in a listing.
    dto = BaseItem.from_item(item)

    refute Map.has_key?(dto, "People")
  end

  test "MediaSources still rides along without a Fields flag", %{item: item} do
    # Guards against 'fixing' People by changing the shared gate.
    dto = BaseItem.from_item(item)

    assert Map.has_key?(dto, "MediaSources")
  end

  test "cast sorts before crew", %{item: item} do
    dto = BaseItem.from_item(item, fields: ["People"])

    assert Enum.map(dto["People"], & &1["Type"]) == ["Actor", "Director"]
  end

  test "an item with no people emits an empty list, not a missing key", %{library: library} do
    # PeopleContext.replace_for_item/2 treats `[]` as a no-op that leaves
    # existing rows untouched (a pre-credits refresh must never wipe good
    # credits) — so reusing the setup item (already 2 rows) can't exercise
    # this. A freshly inserted item with zero ItemPerson rows can.
    {:ok, bare_item} =
      %Item{}
      |> Item.changeset(%{
        name: "No Credits",
        type: :movie,
        sort_name: "no credits",
        library_id: library.id
      })
      |> Repo.insert()

    dto = BaseItem.from_item(bare_item, fields: ["People"])

    assert dto["People"] == []
  end
end
