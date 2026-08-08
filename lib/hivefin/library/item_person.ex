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
