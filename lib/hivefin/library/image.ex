defmodule Hivefin.Library.Image do
  @moduledoc """
  Cached artwork for a library item (poster/backdrop) or a person (headshot).

  Owned by exactly one of `item_id` / `person_id` — enforced by the
  `images_one_owner` DB check constraint, deliberately left undeclared via
  `check_constraint/3` here so a violation raises `Ecto.ConstraintError`
  instead of becoming a soft changeset error: normal call paths
  (`ImageCache.store/3`, `ImageCache.store_person/2`) never pass both or
  neither, so hitting it means application code has a bug.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @types [:primary, :backdrop]

  schema "images" do
    field :type, Ecto.Enum, values: @types
    field :local_path, :string
    field :provider, :string

    belongs_to :item, Hivefin.Library.Item
    belongs_to :person, Hivefin.Library.Person

    timestamps(type: :utc_datetime_usec)
  end

  def types, do: @types

  def changeset(image, attrs) do
    image
    |> cast(attrs, [:type, :local_path, :provider, :item_id, :person_id])
    |> validate_required([:type])
    |> validate_inclusion(:type, @types)
    |> foreign_key_constraint(:item_id)
    |> foreign_key_constraint(:person_id)
    |> unique_constraint([:item_id, :type], name: :images_item_id_type_unique_index)
    |> unique_constraint([:person_id, :type], name: :images_person_id_type_unique_index)
  end
end
