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

    # Scoped to this test's own tmdb ids, not a bare table-wide count: other
    # tests in this suite (e.g. the ImageCache concurrency-race test, which
    # needs a genuinely separate, real Postgres connection and so can't use
    # this test's own sandboxed-and-rolled-back transaction) may commit real
    # Person rows outside this transaction, momentarily visible here too.
    tmdb_ids = Enum.map(people(), &to_string(&1.tmdb_id))

    assert Repo.aggregate(
             from(p in Person, where: fragment("? ->> 'Tmdb'", p.provider_ids) in ^tmdb_ids),
             :count
           ) == 2

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

  test "profile_path updates run in ascending person id order (deadlock-avoidance sort)" do
    # Doesn't (can't, without a genuine concurrent deadlock) prove the
    # deadlock is avoided — it proves the sort that avoids it is actually
    # applied, which is the cheap, reliable half of the guarantee and
    # exactly what a future "this sort looks pointless" edit would delete.
    item = make_item("Sorted Update Order")

    seed = [
      %{tmdb_id: 301, name: "A", role: "", type: "Actor", sort_order: 0, profile_path: "/a1.jpg"},
      %{tmdb_id: 302, name: "B", role: "", type: "Actor", sort_order: 1, profile_path: "/b1.jpg"},
      %{tmdb_id: 303, name: "C", role: "", type: "Actor", sort_order: 2, profile_path: "/c1.jpg"},
      %{tmdb_id: 304, name: "D", role: "", type: "Actor", sort_order: 3, profile_path: "/d1.jpg"}
    ]

    assert {:ok, 4} = PeopleContext.replace_for_item(item.id, seed)

    person_by_tmdb =
      PeopleContext.list_for_item(item.id)
      |> Map.new(&{&1.person.provider_ids["Tmdb"], &1.person})

    ascending_ids =
      person_by_tmdb |> Map.values() |> Enum.map(& &1.id) |> Enum.sort()

    # Feed credits back in the REVERSE of ascending-id order, each with a
    # genuinely different profile_path so update_profile_path/2 issues a
    # real UPDATE for every one of them — a no-op (unchanged) profile_path
    # wouldn't touch the row at all, so ordering couldn't be observed.
    reversed_credits =
      seed
      |> Enum.sort_by(
        fn %{tmdb_id: tmdb_id} -> Map.fetch!(person_by_tmdb, to_string(tmdb_id)).id end,
        :desc
      )
      |> Enum.map(&%{&1 | profile_path: &1.profile_path <> "-v2"})

    test_pid = self()
    handler_id = "people-update-order-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:hivefin, :repo, :query],
      fn _event, _measurements, metadata, _config ->
        # This file runs async: true — sibling tests' own `people` UPDATEs
        # fire the same telemetry event concurrently. replace_for_item/2
        # runs synchronously in the calling process (no Task spawn, unlike
        # a preload), so self() here is reliably this test's own process.
        if self() == test_pid and metadata.source == "people" and is_binary(metadata.query) and
             String.starts_with?(metadata.query, "UPDATE") do
          send(test_pid, {:people_update, List.last(metadata.params)})
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:ok, 4} = PeopleContext.replace_for_item(item.id, reversed_credits)

    updated_ids =
      Stream.repeatedly(fn ->
        receive do
          {:people_update, raw_id} -> Ecto.UUID.load!(raw_id)
        after
          50 -> nil
        end
      end)
      |> Enum.take_while(& &1)

    assert length(updated_ids) == 4
    assert updated_ids == ascending_ids
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
