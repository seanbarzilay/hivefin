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

  test "cast sorts before crew through the batch-preloaded list path", %{library: library} do
    {:ok, item} =
      %Item{}
      |> Item.changeset(%{
        name: "Preload Order",
        type: :movie,
        sort_name: "preload order",
        library_id: library.id
      })
      |> Repo.insert()

    # Crew inserted first, cast second: without an explicit order_by on the
    # preload query, Postgres has no reason to reorder rows and would likely
    # hand them back in this (crew-first) physical order — the opposite of
    # what's asserted below. Only LibraryContext.item_preloads/1 applying
    # PeopleContext.ordered_item_people_query/0 makes cast come first here.
    {:ok, _} =
      PeopleContext.replace_for_item(item.id, [
        %{
          tmdb_id: 1,
          name: "Kevin Lima",
          role: "",
          type: "Director",
          sort_order: nil,
          profile_path: nil
        },
        %{
          tmdb_id: 3084,
          name: "Glenn Close",
          role: "Cruella De Vil",
          type: "Actor",
          sort_order: 0,
          profile_path: nil
        }
      ])

    # The library already holds the setup item too, so fetch the whole page
    # and pick this test's item out of it. preload_people: true is what the
    # controller sets when the request has Fields=People.
    {entries, _total} =
      LibraryContext.list_items_for_parent(library.id, preload_people: true)

    loaded_item = Enum.find(entries, &(&1.id == item.id))

    # Confirms this test actually exercises the preload path, not a fallback
    # query — item_people must be a loaded list, not %NotLoaded{}.
    assert is_list(loaded_item.item_people)

    dto = BaseItem.from_item(loaded_item, fields: ["People"])

    assert Enum.map(dto["People"], & &1["Type"]) == ["Actor", "Director"]
  end

  test "PrimaryImageTag also appears through the batch-preloaded list path", %{library: library} do
    # people_for/1 has two clauses (preloaded item_people vs. list_for_item/1
    # fallback) sharing one person_entry/1 — this guards against a future
    # edit that duplicates that logic and only updates one clause.
    {:ok, item} =
      %Item{}
      |> Item.changeset(%{
        name: "Preload Image",
        type: :movie,
        sort_name: "preload image",
        library_id: library.id
      })
      |> Repo.insert()

    {:ok, _} =
      PeopleContext.replace_for_item(item.id, [
        %{
          tmdb_id: 9999,
          name: "Headshot Haver",
          role: "Someone",
          type: "Actor",
          sort_order: 0,
          profile_path: "/x.jpg"
        }
      ])

    [entry] = PeopleContext.list_for_item(item.id)

    path = Path.join(System.tmp_dir!(), "hs-preload-#{entry.person.id}.jpg")
    File.write!(path, "not-really-a-jpeg")
    on_exit(fn -> File.rm(path) end)

    {:ok, _} =
      %Hivefin.Library.Image{}
      |> Hivefin.Library.Image.changeset(%{
        person_id: entry.person.id,
        type: :primary,
        local_path: path
      })
      |> Repo.insert()

    {entries, _total} = LibraryContext.list_items_for_parent(library.id, preload_people: true)
    loaded_item = Enum.find(entries, &(&1.id == item.id))
    assert is_list(loaded_item.item_people)

    dto = BaseItem.from_item(loaded_item, fields: ["People"])
    [person] = dto["People"]

    assert person["PrimaryImageTag"]
    refute is_nil(person["PrimaryImageTag"])
  end

  test "a listing without Fields=People never queries item_people", %{library: library} do
    # item_people is Fields-gated for a reason: at this server's real scale
    # (7k+ movies), preloading it unconditionally means materializing and
    # discarding every ItemPerson+Person row on every plain listing.
    test_pid = self()
    handler_id = "no-people-preload-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:hivefin, :repo, :query],
      fn _event, _measurements, %{source: source}, _config ->
        # Guard against cross-test noise (this file runs async): Ecto's
        # preloader runs each top-level association's query in its own
        # Task, so the event fires from a different pid than this test's,
        # not this test process itself. Task/Task.Supervisor tag spawned
        # processes with "$callers" precisely for tracing this back —
        # check that instead of self().
        callers = Process.get(:"$callers") || []

        if source == "item_people" and test_pid in [self() | callers] do
          send(test_pid, :item_people_queried)
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    {_entries, _total} = LibraryContext.list_items_for_parent(library.id)

    refute_received :item_people_queried
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

  test "a person with a cached image gets a PrimaryImageTag", %{item: item} do
    [entry | _] = PeopleContext.list_for_item(item.id)

    path = Path.join(System.tmp_dir!(), "hs-#{entry.person.id}.jpg")
    File.write!(path, "not-really-a-jpeg")

    {:ok, _} =
      %Hivefin.Library.Image{}
      |> Hivefin.Library.Image.changeset(%{
        person_id: entry.person.id,
        type: :primary,
        local_path: path
      })
      |> Repo.insert()

    dto = BaseItem.from_item(item, fields: ["People"])
    person = Enum.find(dto["People"], &(&1["Id"] == Hivefin.Jellyfin.Id.format(entry.person.id)))

    assert person["PrimaryImageTag"]
    refute is_nil(person["PrimaryImageTag"])

    File.rm(path)
  end

  test "a person with no image omits PrimaryImageTag rather than sending null", %{item: item} do
    dto = BaseItem.from_item(item, fields: ["People"])

    for p <- dto["People"] do
      refute Map.has_key?(p, "PrimaryImageTag") and is_nil(p["PrimaryImageTag"]),
             "PrimaryImageTag must be absent, not null"
    end
  end
end
