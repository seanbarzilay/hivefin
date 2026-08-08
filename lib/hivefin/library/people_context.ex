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
        |> Person.changeset(%{name: attrs[:name], provider_ids: %{"Tmdb" => key}})
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
        person
    end
  end

  defp upsert_person(attrs) do
    {:ok, person} = %Person{} |> Person.changeset(%{name: attrs[:name]}) |> Repo.insert()
    person
  end

  defp person_by_tmdb_id(key) do
    from(p in Person, where: fragment("? ->> 'Tmdb' = ?", p.provider_ids, ^key))
  end
end
