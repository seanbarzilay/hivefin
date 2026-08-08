# Cast & Crew Metadata Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fetch cast and crew from TMDb, store them as deduplicated people, and expose them to Jellyfin clients as `BaseItemDto.People`, with headshots and browsable person pages.

**Architecture:** Two new tables — `people` (deduped on TMDb person id) and `item_people` (the per-appearance join carrying role, kind, and order). Credits ride along on the TMDb details request we already make via `append_to_response=credits`, so ingest adds no new HTTP call. `Dto.BaseItem` emits `People[]` behind a `Fields=People` check. Person images reuse the existing `ImageCache` by generalising it from item-keyed to owner-keyed.

**Tech Stack:** Elixir, Phoenix, Ecto + PostgreSQL, TMDb API, ExUnit.

**Spec:** `docs/superpowers/specs/2026-08-08-cast-and-crew-design.md`

## Global Constraints

- **Emit `Id`, `Name`, `Role` and `Type` on every `BaseItemPerson`, always.** Only `Id` is required by jellyfin-sdk-kotlin, but jellyfin-web dereferences optional fields with no guard. Three separate bugs on 2026-08-07 came from trusting the SDK's optional/required distinction (`PlayState.IsPaused`, `AdditionalUsers.length`, `RequiredHttpHeaders`). `Role` is `""` for crew, never `null`.
- **`People` is gated on `include_field?(fields, "People")` ALONE.** Do NOT copy the `MediaSources` pattern (`playable? or include_field?(...)`) — that rides along on every playable item and would put a full cast list on all 7,278 movies in a library listing.
- **Crew is filtered to an allowlist**: `Director`, `Writer`, `Producer`, `Composer`. Unknown TMDb `job` values are **dropped**, not mapped to `Unknown`.
- **Re-ingest replaces an item's `item_people` rows wholesale, inside a transaction.** Partial updates leave stale credits behind when a TMDb record is corrected.
- Schema conventions: `@primary_key {:id, :binary_id, autogenerate: true}`, `@foreign_key_type :binary_id`, `timestamps(type: :utc_datetime_usec)`. Migrations use `create table(:x, primary_key: false)` with `add :id, :binary_id, primary_key: true`.
- Run `mix format` on touched files before every commit.
- The suite currently has **8 known pre-existing failures** (4 `AndroidTvGaps` ID-format, 2 `System/Info` version drift, 2 compat `Path`). Do not fix them; do not let the count grow.
- Tests must not call the live TMDb API. Use recorded payloads.

---

## Stage 1 — Cast & crew on item pages

### Task 1: People schema and migration

**Files:**
- Create: `priv/repo/migrations/20260808120000_create_people.exs`
- Create: `lib/hivefin/library/person.ex`
- Create: `lib/hivefin/library/item_person.ex`
- Modify: `lib/hivefin/library/item.ex` — add `has_many :item_people`
- Test: `test/hivefin/library/person_test.exs`

**Interfaces:**
- Produces:
  - `Hivefin.Library.Person` — schema `"people"`, fields `:name` (string, required), `:sort_name` (string), `:provider_ids` (map, default `%{}`); `has_many :item_people`. `Person.changeset/2` downcases `name` into `sort_name` automatically.
  - `Hivefin.Library.ItemPerson` — schema `"item_people"`, fields `:role` (string), `:type` (string, required), `:sort_order` (integer); `belongs_to :item`, `belongs_to :person`. `ItemPerson.changeset/2`.

- [ ] **Step 1: Write the failing test**

```elixir
defmodule Hivefin.Library.PersonTest do
  use Hivefin.DataCase, async: true

  alias Hivefin.Library.{Item, ItemPerson, Person}
  alias Hivefin.Repo

  test "changeset requires a name and derives sort_name" do
    assert %{valid?: false} = Person.changeset(%Person{}, %{})

    cs = Person.changeset(%Person{}, %{name: "Glenn Close"})
    assert cs.valid?
    assert Ecto.Changeset.get_field(cs, :sort_name) == "glenn close"
  end

  test "people are unique per TMDb id" do
    attrs = %{name: "Glenn Close", provider_ids: %{"Tmdb" => "3084"}}
    assert {:ok, _} = %Person{} |> Person.changeset(attrs) |> Repo.insert()

    assert {:error, _} =
             %Person{}
             |> Person.changeset(%{name: "Glenn Close (dup)", provider_ids: %{"Tmdb" => "3084"}})
             |> Repo.insert()
  end

  test "a person with no TMDb id is allowed more than once" do
    # The unique index is on the extracted Tmdb key, which is NULL here, and
    # Postgres does not consider NULLs equal.
    for n <- ["Uncredited A", "Uncredited B"] do
      assert {:ok, _} = %Person{} |> Person.changeset(%{name: n}) |> Repo.insert()
    end
  end

  test "item_people links an item to a person with a role and kind" do
    {:ok, library} =
      Hivefin.Library.LibraryContext.create_library(%{
        name: "M",
        type: :movies,
        path: "/tmp/people-test-#{System.unique_integer([:positive])}"
      })

    {:ok, item} =
      %Item{}
      |> Item.changeset(%{name: "101 Dalmatians", type: :movie, sort_name: "101", library_id: library.id})
      |> Repo.insert()

    {:ok, person} = %Person{} |> Person.changeset(%{name: "Glenn Close"}) |> Repo.insert()

    assert {:ok, link} =
             %ItemPerson{}
             |> ItemPerson.changeset(%{
               item_id: item.id,
               person_id: person.id,
               role: "Cruella De Vil",
               type: "Actor",
               sort_order: 0
             })
             |> Repo.insert()

    assert link.type == "Actor"
    assert link.role == "Cruella De Vil"
  end

  test "item_people requires a type" do
    assert %{valid?: false} = ItemPerson.changeset(%ItemPerson{}, %{role: "X"})
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/hivefin/library/person_test.exs`
Expected: FAIL — `Hivefin.Library.Person is not available`

- [ ] **Step 3a: Write the migration**

```elixir
defmodule Hivefin.Repo.Migrations.CreatePeople do
  use Ecto.Migration

  def change do
    create table(:people, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :text, null: false
      add :sort_name, :text
      add :provider_ids, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    # Dedup key is the TMDb person id specifically, not the name — two actors
    # genuinely share a name, and a bare-name key would merge them.
    # Rows with no Tmdb id extract to NULL, which Postgres never treats as
    # equal, so uncredited people can coexist.
    create unique_index(:people, ["(provider_ids->>'Tmdb')"], name: :people_tmdb_id_unique_index)
    create index(:people, [:sort_name])

    create table(:item_people, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :item_id, references(:items, type: :binary_id, on_delete: :delete_all), null: false
      add :person_id, references(:people, type: :binary_id, on_delete: :delete_all), null: false
      add :role, :text
      add :type, :string, null: false
      add :sort_order, :integer

      timestamps(type: :utc_datetime_usec)
    end

    # A person can appear twice on one item under different kinds (director AND
    # writer is common), so type is part of the key. role is too: an actor
    # occasionally plays two characters in one film.
    create unique_index(:item_people, [:item_id, :person_id, :type, :role],
             name: :item_people_unique_index
           )

    create index(:item_people, [:item_id])
    create index(:item_people, [:person_id])
  end
end
```

- [ ] **Step 3b: Write the schemas**

`lib/hivefin/library/person.ex`:

```elixir
defmodule Hivefin.Library.Person do
  @moduledoc """
  A cast or crew member, deduplicated across items by TMDb person id.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "people" do
    field :name, :string
    field :sort_name, :string
    field :provider_ids, :map, default: %{}

    has_many :item_people, Hivefin.Library.ItemPerson

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(person, attrs) do
    person
    |> cast(attrs, [:name, :sort_name, :provider_ids])
    |> validate_required([:name])
    |> put_sort_name()
    |> unique_constraint(:provider_ids, name: :people_tmdb_id_unique_index)
  end

  defp put_sort_name(changeset) do
    case get_field(changeset, :sort_name) do
      nil ->
        case get_field(changeset, :name) do
          nil -> changeset
          name -> put_change(changeset, :sort_name, String.downcase(name))
        end

      _ ->
        changeset
    end
  end
end
```

`lib/hivefin/library/item_person.ex`:

```elixir
defmodule Hivefin.Library.ItemPerson do
  @moduledoc """
  One person's appearance on one item: their kind (`PersonKind`), the character
  they played, and where they sort in the credits.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "item_people" do
    field :role, :string
    field :type, :string
    field :sort_order, :integer

    belongs_to :item, Hivefin.Library.Item
    belongs_to :person, Hivefin.Library.Person

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(item_person, attrs) do
    item_person
    |> cast(attrs, [:item_id, :person_id, :role, :type, :sort_order])
    |> validate_required([:type])
    |> unique_constraint([:item_id, :person_id, :type, :role], name: :item_people_unique_index)
  end
end
```

- [ ] **Step 3c: Associate from Item**

In `lib/hivefin/library/item.ex`, alongside the existing `has_many :images`:

```elixir
    has_many :item_people, Hivefin.Library.ItemPerson
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix ecto.migrate && mix test test/hivefin/library/person_test.exs`
Expected: PASS (5 tests)

- [ ] **Step 5: Run the full suite**

Run: `mix test`
Expected: 8 pre-existing failures, no new ones.

- [ ] **Step 6: Commit**

```bash
mix format priv/repo/migrations/20260808120000_create_people.exs lib/hivefin/library/person.ex lib/hivefin/library/item_person.ex lib/hivefin/library/item.ex test/hivefin/library/person_test.exs
git add -A
git commit -m "feat: people and item_people schema"
```

---

### Task 2: TMDb credits fetch and mapping

**Files:**
- Modify: `lib/hivefin/metadata/tmdb.ex` — request `append_to_response=credits`, map credits in `normalize_details/1`
- Test: `test/hivefin/metadata/tmdb_credits_test.exs`

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces: `TMDB.movie_details/1`'s returned map gains `:people` — a list of `%{tmdb_id: integer, name: String.t(), role: String.t(), type: String.t(), sort_order: integer | nil, profile_path: String.t() | nil}` — `sort_order` is the TMDb credited order for cast and `nil` for crew, which is what orders cast before crew downstream, cast first (by TMDb `order`) then allowed crew.
- Produces: `Hivefin.Metadata.TMDB.credits_from_payload/1` — public so it can be unit-tested against a recorded payload without HTTP.

The existing `normalize_details/1` returns `%{tmdb_id:, name:, overview:, production_year:, poster_path:, backdrop_path:, premiere_date:}`. Add `:people` to it; do not change the other keys.

**Note on caching:** `movie_details/1` caches the raw body under `"movie:#{tmdb_id}"` via `ProviderCache`. Adding `append_to_response` changes the body shape, so **previously cached entries have no `credits` key**. `credits_from_payload/1` must return `[]` for a payload without credits rather than raising — old cache entries will flow through it until they expire.

- [ ] **Step 1: Write the failing test**

```elixir
defmodule Hivefin.Metadata.TMDbCreditsTest do
  use ExUnit.Case, async: true

  alias Hivefin.Metadata.TMDB

  defp payload do
    %{
      "id" => 10_113,
      "title" => "102 Dalmatians",
      "credits" => %{
        "cast" => [
          %{"id" => 3084, "name" => "Glenn Close", "character" => "Cruella De Vil", "order" => 0,
            "profile_path" => "/close.jpg"},
          %{"id" => 6162, "name" => "Ioan Gruffudd", "character" => "Kevin Shepherd", "order" => 1,
            "profile_path" => nil}
        ],
        "crew" => [
          %{"id" => 1, "name" => "Kevin Lima", "job" => "Director", "department" => "Directing",
            "profile_path" => "/lima.jpg"},
          %{"id" => 2, "name" => "Kristen Buckley", "job" => "Screenplay", "department" => "Writing",
            "profile_path" => nil},
          %{"id" => 3, "name" => "David Newman", "job" => "Original Music Composer",
            "department" => "Sound", "profile_path" => nil},
          %{"id" => 4, "name" => "Edward S. Feldman", "job" => "Producer", "department" => "Production",
            "profile_path" => nil},
          %{"id" => 5, "name" => "Some Body", "job" => "Best Boy Grip", "department" => "Camera",
            "profile_path" => nil}
        ]
      }
    }
  end

  test "cast maps to Actor with character and order" do
    people = TMDB.credits_from_payload(payload())
    cast = Enum.filter(people, &(&1.type == "Actor"))

    assert length(cast) == 2
    assert %{tmdb_id: 3084, name: "Glenn Close", role: "Cruella De Vil", sort_order: 0,
             profile_path: "/close.jpg"} = hd(cast)
  end

  test "crew jobs map to PersonKind values" do
    by_name = Map.new(TMDB.credits_from_payload(payload()), &{&1.name, &1.type})

    assert by_name["Kevin Lima"] == "Director"
    assert by_name["Kristen Buckley"] == "Writer"
    assert by_name["David Newman"] == "Composer"
    assert by_name["Edward S. Feldman"] == "Producer"
  end

  test "unknown crew jobs are dropped, not mapped to Unknown" do
    names = Enum.map(TMDB.credits_from_payload(payload()), & &1.name)

    refute "Some Body" in names
    refute "Unknown" in Enum.map(TMDB.credits_from_payload(payload()), & &1.type)
  end

  test "crew have an empty-string role, never nil" do
    # jellyfin-web may call .length/.trim on Role; null would throw.
    for p <- TMDB.credits_from_payload(payload()), p.type != "Actor" do
      assert p.role == ""
    end
  end

  test "cast sorts before crew, and cast keeps TMDb order" do
    people = TMDB.credits_from_payload(payload())
    types = Enum.map(people, & &1.type)

    assert Enum.take(types, 2) == ["Actor", "Actor"]
    assert Enum.map(Enum.take(people, 2), & &1.sort_order) == [0, 1]
  end

  test "a payload with no credits yields an empty list" do
    # Entries cached before append_to_response was added have no credits key.
    assert TMDB.credits_from_payload(%{"id" => 1, "title" => "Old Cache Entry"}) == []
    assert TMDB.credits_from_payload(%{}) == []
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/hivefin/metadata/tmdb_credits_test.exs`
Expected: FAIL — `function Hivefin.Metadata.TMDB.credits_from_payload/1 is undefined`

- [ ] **Step 3a: Request credits**

In `lib/hivefin/metadata/tmdb.ex`, change the details request so credits ride along on the call we already make:

```elixir
        case get("/movie/#{tmdb_id}", %{"append_to_response" => "credits"}) do
```

- [ ] **Step 3b: Map credits**

Add to `lib/hivefin/metadata/tmdb.ex`:

```elixir
  # TMDb `job` -> Jellyfin PersonKind. Deliberately small: TMDb returns 100+
  # crew rows per film (grips, runners, casting assistants) and Jellyfin
  # clients render none of them. Jobs absent from this map are DROPPED, not
  # mapped to "Unknown", so the table only holds rows a client will show.
  @crew_kinds %{
    "Director" => "Director",
    "Writer" => "Writer",
    "Screenplay" => "Writer",
    "Story" => "Writer",
    "Producer" => "Producer",
    "Executive Producer" => "Producer",
    "Original Music Composer" => "Composer"
  }

  @doc """
  Extracts cast and crew from a TMDb details payload.

  Returns `[]` for a payload without a `"credits"` key — entries cached before
  `append_to_response=credits` was added still flow through here.
  """
  def credits_from_payload(%{"credits" => %{} = credits}) do
    cast =
      credits
      |> Map.get("cast", [])
      |> Enum.map(fn c ->
        %{
          tmdb_id: c["id"],
          name: c["name"],
          role: c["character"] || "",
          type: "Actor",
          sort_order: c["order"] || 0,
          profile_path: c["profile_path"]
        }
      end)
      |> Enum.sort_by(& &1.sort_order)

    crew =
      credits
      |> Map.get("crew", [])
      |> Enum.flat_map(fn c ->
        case Map.fetch(@crew_kinds, c["job"]) do
          {:ok, kind} ->
            [
              %{
                tmdb_id: c["id"],
                name: c["name"],
                # "" not nil — jellyfin-web may call .length on Role.
                role: "",
                type: kind,
                sort_order: nil,
                profile_path: c["profile_path"]
              }
            ]

          :error ->
            []
        end
      end)

    (cast ++ crew)
    |> Enum.reject(&(is_nil(&1.tmdb_id) or is_nil(&1.name)))
  end

  def credits_from_payload(_), do: []
```

- [ ] **Step 3c: Include people in normalized details**

In `normalize_details/1`, add one key. Leave the others untouched:

```elixir
      people: credits_from_payload(body)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/hivefin/metadata/tmdb_credits_test.exs`
Expected: PASS (6 tests)

- [ ] **Step 5: Commit**

```bash
mix format lib/hivefin/metadata/tmdb.ex test/hivefin/metadata/tmdb_credits_test.exs
git add -A
git commit -m "feat: fetch and map TMDb cast and crew credits"
```

---

### Task 3: Store people when metadata is applied

**Files:**
- Create: `lib/hivefin/library/people_context.ex`
- Modify: `lib/hivefin/metadata/worker.ex` — call it from `apply_match/2`
- Test: `test/hivefin/library/people_context_test.exs`

**Interfaces:**
- Consumes: `Hivefin.Library.Person`, `Hivefin.Library.ItemPerson` (Task 1); the `:people` key on a match map (Task 2).
- Produces:
  - `Hivefin.Library.PeopleContext.replace_for_item(item_id :: String.t(), people :: [map()]) :: {:ok, integer()} | {:error, term()}` — upserts each person by TMDb id, deletes the item's existing `item_people` rows, inserts the new ones, all in one transaction. Returns the number of links written.
  - `Hivefin.Library.PeopleContext.list_for_item(item_id :: String.t()) :: [%{person: Person.t(), role: String.t(), type: String.t(), sort_order: integer() | nil}]` — ordered cast-then-crew.

- [ ] **Step 1: Write the failing test**

```elixir
defmodule Hivefin.Library.PeopleContextTest do
  use Hivefin.DataCase, async: true

  alias Hivefin.Library.{Item, LibraryContext, PeopleContext, Person}
  alias Hivefin.Repo

  defp make_item(name) do
    {:ok, library} =
      LibraryContext.create_library(%{
        name: "M-#{System.unique_integer([:positive])}",
        type: :movies,
        path: "/tmp/pc-#{System.unique_integer([:positive])}"
      })

    {:ok, item} =
      %Item{}
      |> Item.changeset(%{name: name, type: :movie, sort_name: String.downcase(name), library_id: library.id})
      |> Repo.insert()

    item
  end

  defp people do
    [
      %{tmdb_id: 3084, name: "Glenn Close", role: "Cruella De Vil", type: "Actor", sort_order: 0, profile_path: "/c.jpg"},
      %{tmdb_id: 1, name: "Kevin Lima", role: "", type: "Director", sort_order: nil, profile_path: nil}
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/hivefin/library/people_context_test.exs`
Expected: FAIL — `Hivefin.Library.PeopleContext is not available`

- [ ] **Step 3a: Write the context**

```elixir
defmodule Hivefin.Library.PeopleContext do
  @moduledoc """
  Reads and writes cast/crew for items.

  Writes are wholesale-replace inside a transaction: a corrected TMDb record
  must not leave stale credits behind.
  """
  import Ecto.Query

  alias Hivefin.Library.{ItemPerson, Person}
  alias Hivefin.Repo

  @doc """
  Replaces an item's cast and crew. Returns `{:ok, links_written}`.
  """
  def replace_for_item(item_id, people) when is_binary(item_id) and is_list(people) do
    Repo.transaction(fn ->
      Repo.delete_all(from(ip in ItemPerson, where: ip.item_id == ^item_id))

      people
      |> Enum.reduce(0, fn attrs, count ->
        person = upsert_person(attrs)

        {:ok, _} =
          %ItemPerson{}
          |> ItemPerson.changeset(%{
            item_id: item_id,
            person_id: person.id,
            role: attrs[:role] || "",
            type: attrs[:type],
            sort_order: attrs[:sort_order]
          })
          |> Repo.insert()

        count + 1
      end)
    end)
  end

  @doc """
  An item's people, cast first (by credited order) then crew, each with the
  loaded `Person`.
  """
  def list_for_item(item_id) when is_binary(item_id) do
    from(ip in ItemPerson,
      where: ip.item_id == ^item_id,
      # Cast first: "Actor" rows carry a sort_order, crew rows do not.
      order_by: [
        asc: fragment("case when ? = 'Actor' then 0 else 1 end", ip.type),
        asc_nulls_last: ip.sort_order,
        asc: ip.inserted_at
      ],
      preload: [:person]
    )
    |> Repo.all()
    |> Enum.map(&%{person: &1.person, role: &1.role, type: &1.type, sort_order: &1.sort_order})
  end

  # Dedup on the TMDb id. A person with no TMDb id gets a fresh row, since we
  # cannot safely merge them by name alone.
  defp upsert_person(%{tmdb_id: tmdb_id} = attrs) when not is_nil(tmdb_id) do
    key = to_string(tmdb_id)

    case Repo.one(from(p in Person, where: fragment("? ->> 'Tmdb' = ?", p.provider_ids, ^key))) do
      nil ->
        {:ok, person} =
          %Person{}
          |> Person.changeset(%{name: attrs[:name], provider_ids: %{"Tmdb" => key}})
          |> Repo.insert()

        person

      person ->
        person
    end
  end

  defp upsert_person(attrs) do
    {:ok, person} = %Person{} |> Person.changeset(%{name: attrs[:name]}) |> Repo.insert()
    person
  end
end
```

- [ ] **Step 3b: Call it from the metadata worker**

In `lib/hivefin/metadata/worker.ex`, `apply_match/2` currently ends with the `Item.changeset` update. Keep that, and store people after it succeeds:

```elixir
    result =
      item
      |> Item.changeset(attrs)
      |> Repo.update()

    # People are stored separately from the item's own columns; a credits
    # failure must not roll back the item metadata we just wrote.
    case match[:people] do
      people when is_list(people) and people != [] ->
        _ = Hivefin.Library.PeopleContext.replace_for_item(item.id, people)

      _ ->
        :ok
    end

    result
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/hivefin/library/people_context_test.exs`
Expected: PASS (6 tests)

- [ ] **Step 5: Run the full suite**

Run: `mix test`
Expected: 8 pre-existing failures, no new ones.

- [ ] **Step 6: Commit**

```bash
mix format lib/hivefin/library/people_context.ex lib/hivefin/metadata/worker.ex test/hivefin/library/people_context_test.exs
git add -A
git commit -m "feat: store cast and crew when item metadata is applied"
```

---

### Task 4: Emit People on BaseItemDto

**Files:**
- Modify: `lib/hivefin/jellyfin/dto/base_item.ex`
- Test: `test/hivefin/jellyfin/dto/base_item_people_test.exs`

**Interfaces:**
- Consumes: `PeopleContext.list_for_item/1` (Task 3).
- Produces: `BaseItemDto["People"]` — a list of `%{"Id" => uuid_string, "Name" => string, "Role" => string, "Type" => string}`, present only when `Fields` includes `"People"`.

`Dto.BaseItem.from_item/2` already computes `fields` and has a private `include_field?(fields, name)`. Follow the existing `maybe_put_media_sources/4` shape but **without** the `playable?` escape hatch.

- [ ] **Step 1: Write the failing test**

```elixir
defmodule Hivefin.Jellyfin.Dto.BaseItemPeopleTest do
  use Hivefin.DataCase, async: true

  alias Hivefin.Jellyfin.Dto.BaseItem
  alias Hivefin.Library.{Item, LibraryContext, PeopleContext}
  alias Hivefin.Repo

  # Listed literally, not read from the implementation — a test that derives
  # its expectations from the code under test agrees with a regression.
  @person_keys ~w(Id Name Role Type)

  setup do
    {:ok, library} =
      LibraryContext.create_library(%{
        name: "M-#{System.unique_integer([:positive])}",
        type: :movies,
        path: "/tmp/bip-#{System.unique_integer([:positive])}"
      })

    {:ok, item} =
      %Item{}
      |> Item.changeset(%{name: "102 Dalmatians", type: :movie, sort_name: "102", library_id: library.id})
      |> Repo.insert()

    {:ok, _} =
      PeopleContext.replace_for_item(item.id, [
        %{tmdb_id: 3084, name: "Glenn Close", role: "Cruella De Vil", type: "Actor", sort_order: 0, profile_path: nil},
        %{tmdb_id: 1, name: "Kevin Lima", role: "", type: "Director", sort_order: nil, profile_path: nil}
      ])

    {:ok, item: Repo.reload(item)}
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

  test "an item with no people emits an empty list, not a missing key", %{item: item} do
    {:ok, 0} = PeopleContext.replace_for_item(item.id, [])
    dto = BaseItem.from_item(item, fields: ["People"])

    assert dto["People"] == []
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/hivefin/jellyfin/dto/base_item_people_test.exs`
Expected: FAIL — `People` key missing

- [ ] **Step 3: Emit People**

In `lib/hivefin/jellyfin/dto/base_item.ex`, add to the pipeline that already ends with `|> maybe_put_media_sources(playable?, fields, sources)`:

```elixir
    |> maybe_put_people(fields, item)
```

and:

```elixir
  # Gated on the Fields check ALONE — deliberately unlike maybe_put_media_sources/4,
  # which also fires for any playable item. Copying that here would attach a full
  # cast list to every movie in a library listing.
  defp maybe_put_people(dto, fields, item) do
    if include_field?(fields, "People") do
      Map.put(dto, "People", people_for(item))
    else
      dto
    end
  end

  defp people_for(%Item{id: id}) when is_binary(id) do
    id
    |> Hivefin.Library.PeopleContext.list_for_item()
    |> Enum.map(fn entry ->
      # All four emitted unconditionally. Only Id is required by
      # jellyfin-sdk-kotlin, but jellyfin-web dereferences optional fields with
      # no guard — the same trap that produced the PlayState and AdditionalUsers
      # crashes on 2026-08-07.
      %{
        "Id" => Hivefin.Jellyfin.Id.format(entry.person.id),
        "Name" => entry.person.name,
        "Role" => entry.role || "",
        "Type" => entry.type
      }
    end)
  end

  defp people_for(_), do: []
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/hivefin/jellyfin/dto/base_item_people_test.exs`
Expected: PASS (6 tests)

- [ ] **Step 5: Run the full suite**

Run: `mix test`
Expected: 8 pre-existing failures, no new ones.

- [ ] **Step 6: Commit and deploy Stage 1**

```bash
mix format lib/hivefin/jellyfin/dto/base_item.ex test/hivefin/jellyfin/dto/base_item_people_test.exs
git add -A
git commit -m "feat: emit People on BaseItemDto behind Fields=People"
git push origin main
ssh root@192.168.1.176 'cd /root/apps/hivefin && git pull --ff-only && mix ecto.migrate'
ssh root@192.168.1.176 'cd /root/apps/hivefin && docker compose up -d --build'
```

**Note on migrations in production:** the release runs migrations via its entrypoint. Confirm how `bin/docker-entrypoint` handles `ecto.migrate` before running the command above — if it migrates on boot, the explicit `mix ecto.migrate` line is unnecessary and will fail (there is no `mix` inside the release image).

- [ ] **Step 7: Verify on the real server**

Existing items have no people until their metadata is refreshed. Trigger a refresh for one movie, then:

```bash
curl -sS "http://192.168.1.176:4000/Users/<userId>/Items/<itemId>?Fields=People&api_key=<token>" | python3 -m json.tool | grep -A6 '"People"'
```

Expected: cast entries with `Id`, `Name`, `Role`, `Type`. Then open the movie in jellyfin-web and confirm the cast section renders.

---

## Stage 2 — Headshots

### Task 5: Person images

**Files:**
- Create: `priv/repo/migrations/20260808130000_add_person_id_to_images.exs`
- Modify: `lib/hivefin/library/image.ex` — add `belongs_to :person`
- Modify: `lib/hivefin/metadata/image_cache.ex` — generalise from item-keyed to owner-keyed
- Test: `test/hivefin/metadata/person_image_test.exs`

**Interfaces:**
- Consumes: `Person` (Task 1).
- Produces:
  - `ImageCache.store_person(person_id :: String.t(), url :: String.t()) :: {:ok, path} | {:error, term()}`
  - `ImageCache.path_for/2` resolves a person id as well as an item id, so `ImagesController` needs **no change** — it already calls `ImageCache.path_for(item_id, image_type)` with whatever id is in the path.

`ImageCache.store/3` is `store(item_id, type, url)` with `type in [:primary, :backdrop]`, and `upsert_image/3` writes an `images` row. Person images are always `:primary`.

- [ ] **Step 1: Write the failing test**

```elixir
defmodule Hivefin.Metadata.PersonImageTest do
  use Hivefin.DataCase, async: true

  alias Hivefin.Library.Person
  alias Hivefin.Metadata.ImageCache
  alias Hivefin.Repo

  setup do
    {:ok, person} =
      %Person{} |> Person.changeset(%{name: "Glenn Close", provider_ids: %{"Tmdb" => "3084"}}) |> Repo.insert()

    {:ok, person: person}
  end

  test "an images row can belong to a person", %{person: person} do
    {:ok, image} =
      %Hivefin.Library.Image{}
      |> Hivefin.Library.Image.changeset(%{person_id: person.id, type: :primary, local_path: "/tmp/x.jpg"})
      |> Repo.insert()

    assert image.person_id == person.id
    assert is_nil(image.item_id)
  end

  test "an images row cannot belong to both an item and a person" do
    # The DB constraint holds the invariant, not application code.
    {:ok, library} =
      Hivefin.Library.LibraryContext.create_library(%{
        name: "M-#{System.unique_integer([:positive])}",
        type: :movies,
        path: "/tmp/pi-#{System.unique_integer([:positive])}"
      })

    {:ok, item} =
      %Hivefin.Library.Item{}
      |> Hivefin.Library.Item.changeset(%{name: "X", type: :movie, sort_name: "x", library_id: library.id})
      |> Repo.insert()

    {:ok, person} = %Person{} |> Person.changeset(%{name: "Both"}) |> Repo.insert()

    assert_raise Ecto.ConstraintError, fn ->
      %Hivefin.Library.Image{}
      |> Hivefin.Library.Image.changeset(%{
        item_id: item.id,
        person_id: person.id,
        type: :primary,
        local_path: "/tmp/y.jpg"
      })
      |> Repo.insert()
    end
  end

  test "an images row must belong to something" do
    assert_raise Ecto.ConstraintError, fn ->
      %Hivefin.Library.Image{}
      |> Hivefin.Library.Image.changeset(%{type: :primary, local_path: "/tmp/z.jpg"})
      |> Repo.insert()
    end
  end

  test "path_for resolves a person id", %{person: person} do
    path = Path.join(System.tmp_dir!(), "person-#{person.id}.jpg")
    File.write!(path, "not-really-a-jpeg")

    {:ok, _} =
      %Hivefin.Library.Image{}
      |> Hivefin.Library.Image.changeset(%{person_id: person.id, type: :primary, local_path: path})
      |> Repo.insert()

    assert {:ok, ^path} = ImageCache.path_for(person.id, "Primary")

    File.rm(path)
  end

  test "path_for returns :error for an unknown id" do
    assert :error = ImageCache.path_for(Ecto.UUID.generate(), "Primary")
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/hivefin/metadata/person_image_test.exs`
Expected: FAIL — `images` has no `person_id`

- [ ] **Step 3a: Migration**

```elixir
defmodule Hivefin.Repo.Migrations.AddPersonIdToImages do
  use Ecto.Migration

  def change do
    alter table(:images) do
      add :person_id, references(:people, type: :binary_id, on_delete: :delete_all)
      modify :item_id, :binary_id, null: true, from: {:binary_id, null: false}
    end

    create index(:images, [:person_id])
    create unique_index(:images, [:person_id, :type], name: :images_person_id_type_unique_index)

    # Exactly one owner. Keeping this in the database means application code
    # cannot drift from the invariant.
    create constraint(:images, :images_one_owner,
             check: "(item_id IS NOT NULL AND person_id IS NULL) OR (item_id IS NULL AND person_id IS NOT NULL)"
           )
  end
end
```

**Before writing this**, check the existing `images` migration: if `item_id` is already nullable, drop the `modify` line. If the existing unique index `images_item_id_type_unique_index` exists (it does, from `20260806232542`), leave it — it stays valid because `item_id` is NULL for person rows.

- [ ] **Step 3b: Schema**

In `lib/hivefin/library/image.ex`, add the association and allow the field in the changeset:

```elixir
    belongs_to :person, Hivefin.Library.Person
```

Add `:person_id` to the `cast/3` list, and add:

```elixir
    |> check_constraint(:item_id, name: :images_one_owner)
```

- [ ] **Step 3c: Generalise the cache**

In `lib/hivefin/metadata/image_cache.ex`, `path_for/2` currently queries images by `item_id`. Change the lookup to match **either** owner:

```elixir
      # An id here may be an item or a person: ImagesController serves person
      # headshots from /Items/{personId}/Images/Primary, matching upstream
      # Jellyfin, where persons are items. Resolving both keeps client URLs
      # identical without making people items.
      from(i in Image,
        where: (i.item_id == ^id or i.person_id == ^id) and i.type == ^type,
        limit: 1
      )
```

Add a person store that writes a person-owned row:

```elixir
  @doc """
  Downloads and caches a person's headshot. Always `:primary`.
  """
  def store_person(person_id, url) when is_binary(person_id) and is_binary(url) do
    with :ok <- ensure_cache_dir(),
         {:ok, body, content_type} <- download(url),
         ext <- extension_for(url, content_type),
         path <- cache_path(person_id, :primary, ext),
         :ok <- write_file(path, body),
         {:ok, _image} <- upsert_person_image(person_id, path) do
      {:ok, path}
    end
  end

  def store_person(_, _), do: {:error, :invalid_args}
```

Mirror the existing `upsert_image/3` as `upsert_person_image/2`, setting `person_id` instead of `item_id`.

- [ ] **Step 4: Run test to verify it passes**

Run: `mix ecto.migrate && mix test test/hivefin/metadata/person_image_test.exs`
Expected: PASS (5 tests)

- [ ] **Step 5: Run the full suite**

Run: `mix test`
Expected: 8 pre-existing failures, no new ones. Existing item-image tests must still pass — `path_for/2` changed shape.

- [ ] **Step 6: Commit**

```bash
mix format priv/repo/migrations/20260808130000_add_person_id_to_images.exs lib/hivefin/library/image.ex lib/hivefin/metadata/image_cache.ex test/hivefin/metadata/person_image_test.exs
git add -A
git commit -m "feat: person-owned images with a one-owner DB constraint"
```

---

### Task 6: Fetch headshots and emit PrimaryImageTag

**Files:**
- Modify: `lib/hivefin/library/people_context.ex` — return `profile_path` so the worker can fetch it
- Modify: `lib/hivefin/metadata/worker.ex` — fetch headshots after storing people
- Modify: `lib/hivefin/jellyfin/dto/base_item.ex` — add `PrimaryImageTag` to each person
- Test: `test/hivefin/jellyfin/dto/base_item_people_test.exs` (extend)

**Interfaces:**
- Consumes: `ImageCache.store_person/2` (Task 5), `TMDB.image_url/2` (existing, `image_url(path, size)`).
- Produces: `BaseItemPerson["PrimaryImageTag"]` — present only for people who have a cached image; **absent** otherwise, never null.

`ImageCache.image_tags_for/1` already builds tags for items; reuse the same tag derivation for a person id.

- [ ] **Step 1: Write the failing test (append to the existing file)**

```elixir
  test "a person with a cached image gets a PrimaryImageTag", %{item: item} do
    [entry | _] = PeopleContext.list_for_item(item.id)

    path = Path.join(System.tmp_dir!(), "hs-#{entry.person.id}.jpg")
    File.write!(path, "not-really-a-jpeg")

    {:ok, _} =
      %Hivefin.Library.Image{}
      |> Hivefin.Library.Image.changeset(%{person_id: entry.person.id, type: :primary, local_path: path})
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/hivefin/jellyfin/dto/base_item_people_test.exs`
Expected: FAIL — no `PrimaryImageTag`

- [ ] **Step 3a: Carry profile_path through the context**

**Do not change `replace_for_item/2`'s return value.** It stays `{:ok, count}` as Task 3 defined it. Widening it to a 3-tuple would force a rewrite of Task 3's and Task 4's assertions mid-plan for no benefit — the pairing can be derived from what already exists.

Add a pure helper that joins the freshly-stored people to the `profile_path` values from the TMDb input, matching on TMDb id:

```elixir
  @doc """
  Pairs stored people with the `profile_path` from their TMDb credit entry.

  Returns `[{person_id, profile_path}]` for people who have one. Matching is by
  TMDb id, which is also the dedup key, so this is exact.
  """
  def headshot_targets(item_id, people) when is_binary(item_id) and is_list(people) do
    by_tmdb_id =
      people
      |> Enum.reject(&is_nil(&1[:profile_path]))
      |> Map.new(fn p -> {to_string(p[:tmdb_id]), p[:profile_path]} end)

    item_id
    |> list_for_item()
    |> Enum.flat_map(fn %{person: person} ->
      case Map.fetch(by_tmdb_id, person.provider_ids["Tmdb"]) do
        {:ok, profile_path} -> [{person.id, profile_path}]
        :error -> []
      end
    end)
    |> Enum.uniq()
  end
```

- [ ] **Step 3b: Fetch in the worker**

In `lib/hivefin/metadata/worker.ex`, where Task 3 called `replace_for_item/2`:

```elixir
      people when is_list(people) and people != [] ->
        case Hivefin.Library.PeopleContext.replace_for_item(item.id, people) do
          {:ok, _count} ->
            # Best-effort: a failed headshot must never fail the item refresh.
            item.id
            |> Hivefin.Library.PeopleContext.headshot_targets(people)
            |> Enum.each(fn {person_id, profile_path} ->
              case Hivefin.Metadata.TMDB.image_url(profile_path, :profile) do
                nil -> :ok
                url -> Hivefin.Metadata.ImageCache.store_person(person_id, url)
              end
            end)

          _ ->
            :ok
        end
```

Check `TMDB.image_url/2`'s accepted sizes before using `:profile`; if the existing implementation only knows `:poster`/`:backdrop`, add a `:profile` size mapping to TMDb's `w185` profile path.

- [ ] **Step 3c: Emit the tag**

In `people_for/1` in `lib/hivefin/jellyfin/dto/base_item.ex`, add the tag when one exists, using `maybe_put/3`-style omission so a person without an image has **no key** rather than a null:

```elixir
      base = %{
        "Id" => Hivefin.Jellyfin.Id.format(entry.person.id),
        "Name" => entry.person.name,
        "Role" => entry.role || "",
        "Type" => entry.type
      }

      case ImageCache.image_tags_for(entry.person.id) do
        %{"Primary" => tag} -> Map.put(base, "PrimaryImageTag", tag)
        _ -> base
      end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/hivefin/jellyfin/dto/base_item_people_test.exs test/hivefin/library/people_context_test.exs`
Expected: PASS (8 + 6 tests). Task 3's assertions are untouched — `replace_for_item/2` still returns `{:ok, count}`.

- [ ] **Step 5: Run the full suite**

Run: `mix test`
Expected: 8 pre-existing failures, no new ones.

- [ ] **Step 6: Commit and deploy Stage 2**

```bash
mix format lib/hivefin/library/people_context.ex lib/hivefin/metadata/worker.ex lib/hivefin/jellyfin/dto/base_item.ex test/hivefin/jellyfin/dto/base_item_people_test.exs test/hivefin/library/people_context_test.exs
git add -A
git commit -m "feat: fetch person headshots and emit PrimaryImageTag"
git push origin main
```

Deploy, refresh one movie's metadata, and confirm in jellyfin-web that cast cards show photographs and that a cast member without a TMDb photo renders without a broken image.

---

## Stage 3 — Browsable people

### Task 7: /Persons endpoints

**Files:**
- Modify: `lib/hivefin/library/people_context.ex` — listing and lookup
- Create: `lib/hivefin_web/controllers/jellyfin/persons_controller.ex`
- Modify: `lib/hivefin_web/router.ex`
- Test: `test/hivefin_web/controllers/jellyfin/persons_test.exs`

**Interfaces:**
- Consumes: `Person`, `PeopleContext`.
- Produces:
  - `PeopleContext.list_people(opts :: keyword()) :: {[Person.t()], integer()}` — `{page, total_count}`; opts `:start_index`, `:limit`, `:search_term`.
  - `PeopleContext.get_person_by_name(name :: String.t()) :: Person.t() | nil`
  - `GET /Persons` → `{"Items": [...], "TotalRecordCount": n, "StartIndex": i}`
  - `GET /Persons/:name` → a single person DTO

Jellyfin addresses `/Persons/{name}` by **name**, not id — that is the upstream contract, not a mistake. Person DTOs are `BaseItemDto`-shaped with `"Type" => "Person"`.

Routes go in the authenticated `scope "/", HivefinWeb.Jellyfin do pipe_through :jellyfin_api` block, **before** the SPA catch-all. Add `persons` to `WebClientController`'s `@api_roots` so an unmatched `/Persons/...` returns a JSON 404 rather than SPA HTML — that exact omission broke the dashboard on 2026-08-07.

- [ ] **Step 1: Write the failing test**

```elixir
defmodule HivefinWeb.Jellyfin.PersonsTest do
  use HivefinWeb.ConnCase, async: true

  alias Hivefin.Library.{Item, LibraryContext, PeopleContext}
  alias Hivefin.Repo

  setup do
    {:ok, user} =
      Hivefin.Accounts.create_user(%{name: "P", username: "personsuser", password: "password1", admin: true})

    {:ok, token, _} =
      Hivefin.Accounts.issue_token(user, %{
        device_id: "d", device_name: "D", client: "Jellyfin Web", client_version: "10.10.7"
      })

    {:ok, library} =
      LibraryContext.create_library(%{
        name: "M-#{System.unique_integer([:positive])}",
        type: :movies,
        path: "/tmp/persons-#{System.unique_integer([:positive])}"
      })

    {:ok, item} =
      %Item{}
      |> Item.changeset(%{name: "102 Dalmatians", type: :movie, sort_name: "102", library_id: library.id})
      |> Repo.insert()

    {:ok, _} =
      PeopleContext.replace_for_item(item.id, [
        %{tmdb_id: 3084, name: "Glenn Close", role: "Cruella De Vil", type: "Actor", sort_order: 0, profile_path: nil},
        %{tmdb_id: 1, name: "Kevin Lima", role: "", type: "Director", sort_order: nil, profile_path: nil}
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

  test "GET /Persons/:name 404s as JSON for an unknown name", %{conn: conn} do
    conn = get(conn, "/Persons/Nobody%20At%20All")

    assert conn.status == 404
    refute response(conn, 404) =~ "<", "must be JSON, not SPA HTML"
  end

  test "GET /Persons requires authentication" do
    assert json_response(get(build_conn(), "/Persons"), 401)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/hivefin_web/controllers/jellyfin/persons_test.exs`
Expected: FAIL — no route matches `/Persons`

- [ ] **Step 3a: Context queries**

```elixir
  @doc """
  A page of people plus the total count, ordered by sort_name.
  """
  def list_people(opts \\ []) do
    start_index = Keyword.get(opts, :start_index, 0)
    limit = Keyword.get(opts, :limit)
    search = Keyword.get(opts, :search_term)

    base =
      from(p in Person, order_by: [asc: p.sort_name])
      |> then(fn q ->
        if is_binary(search) and search != "" do
          pattern = "%#{String.downcase(search)}%"
          from(p in q, where: like(p.sort_name, ^pattern))
        else
          q
        end
      end)

    total = Repo.aggregate(base, :count)

    page =
      base
      |> offset(^start_index)
      |> then(fn q -> if limit, do: limit(q, ^limit), else: q end)
      |> Repo.all()

    {page, total}
  end

  @doc "Looks a person up by exact name, case-insensitively."
  def get_person_by_name(name) when is_binary(name) do
    Repo.one(from(p in Person, where: p.sort_name == ^String.downcase(name), limit: 1))
  end
```

- [ ] **Step 3b: Controller**

```elixir
defmodule HivefinWeb.Jellyfin.PersonsController do
  @moduledoc """
  `GET /Persons` and `GET /Persons/{name}`.

  Jellyfin addresses a single person by **name**, not id — that is the upstream
  contract. Person DTOs are BaseItemDto-shaped with `Type: "Person"`.
  """
  use HivefinWeb, :controller

  alias Hivefin.Library.PeopleContext
  alias Hivefin.Metadata.ImageCache

  def index(conn, params) do
    start_index = parse_int(params["StartIndex"] || params["startIndex"]) || 0
    limit = parse_int(params["Limit"] || params["limit"])
    search = params["SearchTerm"] || params["searchTerm"]

    {people, total} =
      PeopleContext.list_people(start_index: start_index, limit: limit, search_term: search)

    json(conn, %{
      "Items" => Enum.map(people, &person_dto/1),
      "TotalRecordCount" => total,
      "StartIndex" => start_index
    })
  end

  def show(conn, %{"name" => name}) do
    case PeopleContext.get_person_by_name(name) do
      nil -> conn |> put_status(:not_found) |> json(%{"error" => "not_found"})
      person -> json(conn, person_dto(person))
    end
  end

  defp person_dto(person) do
    base = %{
      "Id" => Hivefin.Jellyfin.Id.format(person.id),
      "Name" => person.name,
      "Type" => "Person",
      "MediaType" => "Unknown",
      "IsFolder" => false,
      "ImageTags" => %{},
      "ServerId" => Hivefin.Jellyfin.Id.format(Hivefin.Jellyfin.SystemInfo.server_id())
    }

    case ImageCache.image_tags_for(person.id) do
      %{"Primary" => tag} -> %{base | "ImageTags" => %{"Primary" => tag}}
      _ -> base
    end
  end

  defp parse_int(nil), do: nil
  defp parse_int(n) when is_integer(n), do: n

  defp parse_int(n) when is_binary(n) do
    case Integer.parse(n) do
      {i, _} -> i
      :error -> nil
    end
  end

  defp parse_int(_), do: nil
end
```

- [ ] **Step 3c: Routes and the SPA guard**

In the authenticated `pipe_through :jellyfin_api` scope:

```elixir
    get "/Persons", PersonsController, :index
    get "/Persons/:name", PersonsController, :show
```

In `lib/hivefin_web/controllers/jellyfin/web_client_controller.ex`, add `persons` to `@api_roots`, so an unmatched `/Persons/...` returns a JSON 404 rather than the SPA HTML page.

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/hivefin_web/controllers/jellyfin/persons_test.exs`
Expected: PASS (6 tests)

- [ ] **Step 5: Commit**

```bash
mix format lib/hivefin/library/people_context.ex lib/hivefin_web/controllers/jellyfin/persons_controller.ex lib/hivefin_web/router.ex lib/hivefin_web/controllers/jellyfin/web_client_controller.ex test/hivefin_web/controllers/jellyfin/persons_test.exs
git add -A
git commit -m "feat: /Persons listing and lookup"
```

---

### Task 8: personIds filter on /Items

**Files:**
- Modify: `lib/hivefin/library/library_context.ex` — accept a `:person_ids` filter
- Modify: `lib/hivefin_web/controllers/jellyfin/items_controller.ex` — parse `PersonIds`
- Test: `test/hivefin_web/controllers/jellyfin/items_person_filter_test.exs`

**Interfaces:**
- Consumes: `item_people` (Task 1).
- Produces: `GET /Items?PersonIds=<id>` returns only items that person appears in. Accepts a comma-separated list and both dashed and dashless id forms.

**Ids arrive dashless.** Every id hivefin gives a client is dashless (`Id.format/1`), while the database stores dashed UUIDs. Coerce with `Hivefin.Jellyfin.Id.coerce/1` before querying — a raw dashless id silently matches nothing. This exact mistake made every remote-control command 404 on 2026-08-07.

- [ ] **Step 1: Write the failing test**

```elixir
defmodule HivefinWeb.Jellyfin.ItemsPersonFilterTest do
  use HivefinWeb.ConnCase, async: true

  alias Hivefin.Library.{Item, LibraryContext, PeopleContext}
  alias Hivefin.Repo

  setup do
    {:ok, user} =
      Hivefin.Accounts.create_user(%{name: "F", username: "filteruser", password: "password1", admin: true})

    {:ok, token, _} =
      Hivefin.Accounts.issue_token(user, %{
        device_id: "d", device_name: "D", client: "Jellyfin Web", client_version: "10.10.7"
      })

    {:ok, library} =
      LibraryContext.create_library(%{
        name: "M-#{System.unique_integer([:positive])}",
        type: :movies,
        path: "/tmp/filter-#{System.unique_integer([:positive])}"
      })

    insert = fn name ->
      {:ok, i} =
        %Item{}
        |> Item.changeset(%{name: name, type: :movie, sort_name: String.downcase(name), library_id: library.id})
        |> Repo.insert()

      i
    end

    with_close = insert.("102 Dalmatians")
    without = insert.("Some Other Film")

    {:ok, _} =
      PeopleContext.replace_for_item(with_close.id, [
        %{tmdb_id: 3084, name: "Glenn Close", role: "Cruella", type: "Actor", sort_order: 0, profile_path: nil}
      ])

    {:ok, _} =
      PeopleContext.replace_for_item(without.id, [
        %{tmdb_id: 999, name: "Someone Else", role: "Extra", type: "Actor", sort_order: 0, profile_path: nil}
      ])

    [entry] = PeopleContext.list_for_item(with_close.id)

    conn =
      build_conn()
      |> put_req_header(
        "x-emby-authorization",
        ~s(MediaBrowser Client="Jellyfin Web", Device="D", DeviceId="d", Version="10.10.7", Token="#{token}")
      )

    {:ok, conn: conn, person: entry.person, with_close: with_close, without: without}
  end

  test "PersonIds filters to that person's items, using the DASHLESS id clients get",
       %{conn: conn, person: person, with_close: with_close} do
    dashless = Hivefin.Jellyfin.Id.format(person.id)
    refute dashless == person.id, "test must use the wire form, not the DB form"

    body = json_response(get(conn, "/Items?PersonIds=#{dashless}&Recursive=true"), 200)
    ids = Enum.map(body["Items"], & &1["Id"])

    assert Hivefin.Jellyfin.Id.format(with_close.id) in ids
    assert length(ids) == 1
  end

  test "the dashed form works too", %{conn: conn, person: person, with_close: with_close} do
    body = json_response(get(conn, "/Items?PersonIds=#{person.id}&Recursive=true"), 200)

    assert Enum.map(body["Items"], & &1["Id"]) == [Hivefin.Jellyfin.Id.format(with_close.id)]
  end

  test "no PersonIds returns everything", %{conn: conn} do
    body = json_response(get(conn, "/Items?Recursive=true"), 200)

    assert length(body["Items"]) == 2
  end

  test "an unknown person id returns no items", %{conn: conn} do
    body = json_response(get(conn, "/Items?PersonIds=#{Ecto.UUID.generate()}&Recursive=true"), 200)

    assert body["Items"] == []
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/hivefin_web/controllers/jellyfin/items_person_filter_test.exs`
Expected: FAIL — the filter is ignored, so both items come back

- [ ] **Step 3a: Context filter**

In `library_context.ex`'s item-listing query builder, add:

```elixir
      |> then(fn q ->
        case opts[:person_ids] do
          ids when is_list(ids) and ids != [] ->
            # Ids arrive dashless from clients; the DB stores dashed UUIDs.
            coerced = Enum.map(ids, &Hivefin.Jellyfin.Id.coerce/1)

            from(i in q,
              join: ip in Hivefin.Library.ItemPerson,
              on: ip.item_id == i.id,
              where: ip.person_id in ^coerced,
              distinct: true
            )

          _ ->
            q
        end
      end)
```

- [ ] **Step 3b: Controller parsing**

In `items_controller.ex`, where other filters are parsed:

```elixir
    person_ids =
      (params["PersonIds"] || params["personIds"] || "")
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
```

and pass `person_ids: person_ids` into the listing opts.

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/hivefin_web/controllers/jellyfin/items_person_filter_test.exs`
Expected: PASS (4 tests)

- [ ] **Step 5: Run the full suite**

Run: `mix test`
Expected: 8 pre-existing failures, no new ones.

- [ ] **Step 6: Commit and deploy Stage 3**

```bash
mix format lib/hivefin/library/library_context.ex lib/hivefin_web/controllers/jellyfin/items_controller.ex test/hivefin_web/controllers/jellyfin/items_person_filter_test.exs
git add -A
git commit -m "feat: filter items by PersonIds"
git push origin main
```

Deploy, then click a cast member in jellyfin-web and confirm their page lists their titles.

---

## Stage 4 — TV credits

### Task 9: Series and episode credits

**Files:**
- Modify: `lib/hivefin/metadata/tmdb.ex` — series and episode credit fetches
- Modify: `lib/hivefin/metadata/provider.ex` — new callbacks
- Modify: `lib/hivefin/metadata/worker.ex` — handle `:series` and `:episode`
- Test: `test/hivefin/metadata/tv_credits_test.exs`

**Interfaces:**
- Consumes: `credits_from_payload/1` (Task 2), `PeopleContext.replace_for_item/2` (Task 3).
- Produces:
  - `TMDB.series_details(tmdb_id) :: {:ok, map()} | {:error, term()}` — same shape as `movie_details/1`, including `:people`
  - `TMDB.episode_credits(tmdb_id, season, episode) :: {:ok, [map()]} | {:error, term()}`

**Episode people are guest stars and that episode's crew only** — not the series regulars. A client shows the series cast on the series page and guest stars on the episode; duplicating regulars onto every episode would multiply `item_people` by the episode count for no display benefit.

TMDb paths: `/tv/{id}?append_to_response=credits` and `/tv/{id}/season/{s}/episode/{e}/credits` (whose payload has `cast`, `crew`, and `guest_stars`).

**This stage cannot be verified against production data.** The server has no TV library and zero TV items — 7,278 movies only. It ships on test coverage; confirm by hand once a TV library exists. Treat every TV assumption here as unexercised.

- [ ] **Step 1: Write the failing test**

```elixir
defmodule Hivefin.Metadata.TvCreditsTest do
  use ExUnit.Case, async: true

  alias Hivefin.Metadata.TMDB

  test "episode credits include guest stars as Actors" do
    payload = %{
      "cast" => [%{"id" => 10, "name" => "Regular", "character" => "Self", "order" => 0, "profile_path" => nil}],
      "guest_stars" => [%{"id" => 11, "name" => "Guest", "character" => "Villain", "order" => 0, "profile_path" => nil}],
      "crew" => [%{"id" => 12, "name" => "Ep Director", "job" => "Director", "department" => "Directing", "profile_path" => nil}]
    }

    people = TMDB.episode_people_from_payload(payload)
    by_name = Map.new(people, &{&1.name, &1.type})

    assert by_name["Guest"] == "Actor"
    assert by_name["Ep Director"] == "Director"
  end

  test "series regulars are NOT copied onto episodes" do
    payload = %{
      "cast" => [%{"id" => 10, "name" => "Regular", "character" => "Self", "order" => 0, "profile_path" => nil}],
      "guest_stars" => [],
      "crew" => []
    }

    names = Enum.map(TMDB.episode_people_from_payload(payload), & &1.name)

    refute "Regular" in names
  end

  test "an episode payload with no guest stars or crew yields an empty list" do
    assert TMDB.episode_people_from_payload(%{"cast" => [], "guest_stars" => [], "crew" => []}) == []
    assert TMDB.episode_people_from_payload(%{}) == []
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/hivefin/metadata/tv_credits_test.exs`
Expected: FAIL — `episode_people_from_payload/1` is undefined

- [ ] **Step 3a: Episode people**

In `lib/hivefin/metadata/tmdb.ex`:

```elixir
  @doc """
  People for one episode: guest stars plus that episode's own crew.

  Series regulars (`"cast"`) are deliberately excluded — clients show them on
  the series page, and copying them onto every episode would multiply
  `item_people` by the episode count for no display benefit.
  """
  def episode_people_from_payload(%{} = payload) do
    guests =
      payload
      |> Map.get("guest_stars", [])
      |> Enum.map(fn g ->
        %{
          tmdb_id: g["id"],
          name: g["name"],
          role: g["character"] || "",
          type: "GuestStar",
          sort_order: g["order"] || 0,
          profile_path: g["profile_path"]
        }
      end)

    crew = credits_from_payload(%{"credits" => %{"cast" => [], "crew" => Map.get(payload, "crew", [])}})

    (guests ++ crew) |> Enum.reject(&(is_nil(&1.tmdb_id) or is_nil(&1.name)))
  end

  def episode_people_from_payload(_), do: []
```

**Note:** the test asserts guest stars map to `"Actor"`, but `PersonKind` also has `GuestStar`, which is the more accurate value and what upstream uses. Pick `"GuestStar"` and **update the test's first assertion to match** — do not weaken the implementation to satisfy a test assertion written before the enum was checked. Record the choice in your report.

- [ ] **Step 3b: Series details**

Mirror `movie_details/1` as `series_details/1` against `/tv/#{tmdb_id}` with `append_to_response=credits`, caching under `"tv:#{tmdb_id}"`. Add both new functions to the `Hivefin.Metadata.Provider` behaviour as callbacks.

- [ ] **Step 3c: Worker handles series and episodes**

`Metadata.Worker.refresh_item/1` currently matches `%Item{type: :movie}` only. Add clauses for `%Item{type: :series}` (series details + credits) and `%Item{type: :episode}` (episode credits, using the parent season/series for the TMDb id and the item's `index_number`/`parent_index_number`). Leave `:season` unhandled — TMDb has no meaningful season-level cast and Jellyfin does not display one.

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/hivefin/metadata/tv_credits_test.exs`
Expected: PASS (3 tests)

- [ ] **Step 5: Run the full suite**

Run: `mix test`
Expected: 8 pre-existing failures, no new ones.

- [ ] **Step 6: Commit**

```bash
mix format lib/hivefin/metadata/tmdb.ex lib/hivefin/metadata/provider.ex lib/hivefin/metadata/worker.ex test/hivefin/metadata/tv_credits_test.exs
git add -A
git commit -m "feat: series and episode credits"
```

---

## Verification summary

| Stage | Server-side check | Client check |
|-------|------------------|--------------|
| 1 | `?Fields=People` returns entries with all four keys non-null | Cast section renders on a movie page |
| 2 | Person with an image has `PrimaryImageTag`; one without has no such key | Cast cards show photos; missing photos render cleanly |
| 3 | `/Persons` pages and filters; `/Items?PersonIds=` returns the right titles | Clicking a cast member opens their page |
| 4 | Episode people are guest stars + episode crew, never series regulars | **Unverifiable — no TV library exists** |

Known pre-existing failures that must stay at 8: 4 `AndroidTvGaps` (ID format), 2 `System/Info` (version drift), 2 compat (`Path` assertion).
