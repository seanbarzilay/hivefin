defmodule Hivefin.Library.PeopleContext do
  @moduledoc """
  Reads and writes cast/crew for items.

  Writes are wholesale-replace inside a transaction: a corrected TMDb record
  must not leave stale credits behind.
  """
  import Ecto.Query

  alias Hivefin.Library.{Image, ItemPerson, Person}
  alias Hivefin.Repo

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
