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
    field :profile_path, :string

    has_many :item_people, Hivefin.Library.ItemPerson

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(person, attrs) do
    person
    |> cast(attrs, [:name, :sort_name, :provider_ids, :profile_path])
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
