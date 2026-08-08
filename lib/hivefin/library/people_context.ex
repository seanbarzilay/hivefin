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
