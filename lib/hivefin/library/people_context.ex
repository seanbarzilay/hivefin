defmodule Hivefin.Library.PeopleContext do
  @moduledoc """
  Reads and writes cast/crew for items.

  Writes are wholesale-replace inside a transaction: a corrected TMDb record
  must not leave stale credits behind.
  """
  import Ecto.Query

  alias Hivefin.Jellyfin.{Id, Params}
  alias Hivefin.Library.{Image, Item, ItemPerson, Person}
  alias Hivefin.Repo

  # GET /Persons has no natural scope (no ParentId/library to narrow it, unlike
  # /Items) and the table is 162,800+ rows in production — an unpaged request
  # must not try to serialize the whole thing. ItemsController.latest/2 sets
  # the same kind of precedent (defaults Limit to 16 when absent) for the same
  # reason. Only applied when the caller omits :limit entirely; an explicit
  # Limit (even a huge one) is the client's call, same as ItemsController.
  @default_list_limit 100

  @doc """
  A page of people plus the total count, ordered by sort_name (id as a
  tie-breaker — see the moduledoc note below on why that's required).

  `opts`:
  - `:start_index` — offset, defaults to 0. Negative values are clamped to 0
    (Postgres raises on a negative OFFSET rather than tolerating one).
  - `:limit` — page size; defaults to #{@default_list_limit} when omitted
    (never omitted from the query — see the moduledoc note on production
    scale). Negative values are clamped to 0 for the same reason (Postgres
    raises on a negative LIMIT); an explicit non-negative value, however
    large, is passed through as-is — the client's call, same as `:limit`.
  - `:search_term` — case-insensitive substring match against sort_name
  """
  def list_people(opts \\ []) do
    start_index = Params.clamp_non_neg(Keyword.get(opts, :start_index, 0)) || 0
    limit = Params.clamp_non_neg(Keyword.get(opts, :limit)) || @default_list_limit
    search = Keyword.get(opts, :search_term)

    # sort_name alone is not enough at 162,800 rows: common-surname
    # collisions are routine, and the table takes continuous concurrent
    # writes from background metadata refresh. SQL guarantees nothing
    # about the relative order of tied rows across two separate
    # OFFSET/LIMIT queries, so a client paging StartIndex=0,100,200... on
    # sort_name alone can see a person twice or miss one — either when a
    # write lands near a page boundary, or simply because the planner
    # picks a different scan strategy as the table grows. `id` never ties,
    # so appending it (same tie-break `get_person_by_name/1` already uses
    # for duplicate names) makes the order — and therefore the pages —
    # fully deterministic.
    base =
      from(p in Person, order_by: [asc: p.sort_name, asc: p.id])
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
      |> limit(^limit)
      |> Repo.all()

    {page, total}
  end

  @doc """
  Looks a person up by id, accepting the dashless form clients are handed.

  Returns `nil` — never raises — for anything that isn't a well-formed id, so
  a caller can use it as a "is this id a person?" fallback (see
  `HivefinWeb.Jellyfin.ItemsController.show/2`) without first proving the id
  is a UUID.
  """
  def get_person(id) do
    case Id.normalize(id) do
      {:ok, dashed} -> Repo.get(Person, dashed)
      :error -> nil
    end
  end

  @doc """
  How many items of each type one person is credited in, keyed by
  `Hivefin.Library.Item` type: `%{movie: 12, episode: 3}`. Types with no
  credits are absent.

  One grouped index scan on `item_people(person_id)` joined to `items` by
  primary key — cheap per call, but strictly a **single-person** query. Never
  call it while building a list page: `/Persons` renders up to 100 DTOs per
  request, which would make this N grouped queries per page.
  """
  def credit_counts(person_id) when is_binary(person_id) do
    from(ip in ItemPerson,
      join: i in Item,
      on: i.id == ip.item_id,
      where: ip.person_id == ^person_id,
      group_by: i.type,
      # A person credited twice on one item (director AND writer) is two
      # item_people rows but one film.
      select: {i.type, count(ip.item_id, :distinct)}
    )
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  Looks a person up by exact name, case-insensitively.

  Jellyfin addresses `/Persons/{name}` by name, not id. Names are not unique
  at this scale (162,800 people) — two people can share a name — so ties are
  broken deterministically by lowest `id` (`order_by` + the query's implicit
  `limit: 1` mean only one row is ever fetched) rather than left to whatever
  order Postgres happens to return, which is not guaranteed stable across
  plans. This mirrors upstream Jellyfin, which has no dedup story for
  same-named people either — an arbitrary-but-stable pick is not a
  regression.
  """
  def get_person_by_name(name) when is_binary(name) do
    Repo.one(
      from(p in Person,
        where: p.sort_name == ^String.downcase(name),
        order_by: [asc: p.id],
        limit: 1
      )
    )
  end

  @doc """
  Replaces an item's cast and crew. Returns `{:ok, links_written}`.

  `people: []` is a no-op that leaves existing rows untouched — a match map
  with no credits (e.g. a pre-credits cache entry) must never wipe good
  credits an item already has. Only a non-empty list triggers the
  delete-then-insert replace.
  """
  def replace_for_item(item_id, []) when is_binary(item_id) do
    {:ok, 0}
  end

  def replace_for_item(item_id, people) when is_binary(item_id) and is_list(people) do
    Repo.transaction(fn ->
      Repo.delete_all(from(ip in ItemPerson, where: ip.item_id == ^item_id))

      # Deterministic INSERT order for brand-new people: two movies sharing
      # not-yet-seen cast in a different credit order (franchise films,
      # repeat collaborators), refreshed concurrently at Metadata.Queue's
      # max_concurrency: 2, can deadlock each other in upsert_person/1's
      # SELECT-then-INSERT path — transaction A inserts person X then blocks
      # inserting Y (which B is mid-inserting), while B inserts Y then
      # blocks inserting X (which A is mid-inserting): a lock cycle, and
      # Postgres aborts one with `deadlock_detected`, silently swallowed by
      # Worker.refresh_item/1's rescue. The sort_by(person id) pass below
      # (from update_profile_path/2's Repo.update) only covers people that
      # already exist — a brand-new person has no id to sort by until AFTER
      # it's inserted, so it can't be the fix for this path. tmdb_id is
      # known up front and stable regardless of credit order, so sorting by
      # it here — before any INSERT runs — makes concurrent refreshes always
      # attempt the same not-yet-existing people in the same order. Only
      # entries with a tmdb_id go through the conflict-checked path; a
      # person with none always inserts a fresh, non-competing row (see
      # upsert_person/1) and is left out here on purpose.
      people
      |> Enum.filter(& &1[:tmdb_id])
      |> Enum.sort_by(& &1[:tmdb_id])
      |> Enum.each(&upsert_person/1)

      rows =
        people
        |> Enum.map(&{upsert_person(&1), &1})
        # Two crew jobs can map to the same {type, role} (Story + Screenplay
        # both become type: "Writer", role: ""). item_people_unique_index is
        # keyed on [:item_id, :person_id, :type, :role], so without this the
        # second insert is a genuine duplicate-key error, not a race.
        |> Enum.uniq_by(fn {person, attrs} -> {person.id, attrs[:type], attrs[:role] || ""} end)

      # Deterministic lock order: two movies sharing cast in a different
      # credit order (franchise films, repeat collaborators), refreshed
      # concurrently at Metadata.Queue's max_concurrency: 2, must take
      # `people` row write locks (from update_profile_path/2's Repo.update)
      # in the same order, or Postgres can deadlock them — one transaction
      # gets aborted, Worker.refresh_item/1's rescue swallows it, and that
      # movie silently keeps stale credits. Sorting by person id — the same
      # value regardless of which movie's credit list mentions them first —
      # guarantees a shared order. This looks pointless (nothing below
      # depends on row order) until it's deleted and a franchise refresh
      # deadlocks under concurrent load.
      rows
      |> Enum.uniq_by(fn {person, _attrs} -> person.id end)
      |> Enum.sort_by(fn {person, _attrs} -> person.id end)
      |> Enum.each(fn {person, attrs} -> update_profile_path(person, attrs[:profile_path]) end)

      Enum.each(rows, fn {person, attrs} ->
        changeset =
          ItemPerson.changeset(%ItemPerson{}, %{
            item_id: item_id,
            person_id: person.id,
            role: attrs[:role] || "",
            type: attrs[:type],
            sort_order: attrs[:sort_order]
          })

        case Repo.insert(changeset) do
          {:ok, _} -> :ok
          {:error, changeset} -> Repo.rollback(changeset)
        end
      end)

      length(rows)
    end)
  end

  @doc """
  An item's people, cast first (by credited order) then crew, each with the
  loaded `Person`.
  """
  def list_for_item(item_id) when is_binary(item_id) do
    ordered_item_people_query()
    |> where([ip], ip.item_id == ^item_id)
    |> Repo.all()
    |> Enum.map(&%{person: &1.person, role: &1.role, type: &1.type, sort_order: &1.sort_order})
  end

  @doc """
  The `item_people` query, cast-before-crew ordered with `:person` preloaded.

  Shared with `LibraryContext.item_preloads/1` so a batch preload across a
  list page of items sorts identically to a single-item `list_for_item/1`
  call — the ordering lives in exactly one place, never duplicated.
  """
  def ordered_item_people_query do
    from(ip in ItemPerson,
      # Cast first: "Actor" rows carry a sort_order, crew rows do not.
      order_by: [
        asc: fragment("case when ? = 'Actor' then 0 else 1 end", ip.type),
        asc_nulls_last: ip.sort_order,
        asc: ip.inserted_at
      ],
      preload: [:person]
    )
  end

  # Dedup on the TMDb id. A person with no TMDb id gets a fresh row, since we
  # cannot safely merge them by name alone.
  defp upsert_person(%{tmdb_id: tmdb_id} = attrs) when not is_nil(tmdb_id) do
    key = to_string(tmdb_id)

    case Repo.one(person_by_tmdb_id(key)) do
      nil ->
        %Person{}
        |> Person.changeset(%{
          name: attrs[:name],
          provider_ids: %{"Tmdb" => key},
          profile_path: attrs[:profile_path]
        })
        |> Repo.insert()
        |> case do
          {:ok, person} ->
            person

          {:error, _changeset} ->
            # Metadata.Queue runs max_concurrency: 2: another item's refresh
            # inserted this same TMDb id between our SELECT and INSERT.
            # Postgres blocked our insert until theirs committed, so their
            # row is visible now — use it instead of crashing.
            Repo.one!(person_by_tmdb_id(key))
        end

      person ->
        # profile_path is NOT updated here — see update_profile_path/2,
        # called from replace_for_item/2's separate, deterministically
        # sorted pass (lock-ordering, avoids a deadlock across concurrent
        # movie refreshes).
        person
    end
  end

  defp upsert_person(attrs) do
    {:ok, person} =
      %Person{}
      |> Person.changeset(%{name: attrs[:name], profile_path: attrs[:profile_path]})
      |> Repo.insert()

    person
  end

  # Backfills a previously-nil profile_path, or follows TMDb if it changes a
  # photo. Every refresh re-ingests full credits, so this is also how a
  # cached-match re-apply (no new API call) populates profile_path on rows
  # created before this column existed.
  #
  # Called from replace_for_item/2's deterministically-sorted pass, never
  # inline during upsert_person/1 — see the lock-ordering comment there.
  #
  # A no-op (returns person unchanged) when profile_path is nil or
  # unchanged, so a normal re-refresh with identical data does zero writes.
  defp update_profile_path(person, profile_path)
       when is_binary(profile_path) and person.profile_path != profile_path do
    case person |> Person.changeset(%{profile_path: profile_path}) |> Repo.update() do
      {:ok, updated} ->
        invalidate_cached_image(updated)
        updated

      {:error, _changeset} ->
        person
    end
  end

  defp update_profile_path(person, _profile_path), do: person

  # A changed profile_path (TMDb swapped the photo, or a previously-nil path
  # got backfilled) makes any cached headshot — or the negative-cache marker
  # ImageCache.store_person/2 persists after a confirmed failed fetch
  # (`local_path: nil`) — stale. Deleting the Image row is what makes
  # ImagesController's next request a genuine miss instead of serving the
  # old photo or staying blocked by an old failure; ImageCache re-downloads
  # and overwrites the same on-disk path from there.
  defp invalidate_cached_image(%Person{id: person_id}) do
    case Repo.get_by(Image, person_id: person_id, type: :primary) do
      nil ->
        :ok

      image ->
        if is_binary(image.local_path), do: File.rm(image.local_path)
        Repo.delete(image)
        :ok
    end
  end

  defp person_by_tmdb_id(key) do
    from(p in Person, where: fragment("? ->> 'Tmdb' = ?", p.provider_ids, ^key))
  end
end
