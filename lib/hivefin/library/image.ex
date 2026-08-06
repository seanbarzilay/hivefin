defmodule Hivefin.Library.Image do
  @moduledoc """
  Cached artwork for a library item (poster/backdrop).
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

    timestamps(type: :utc_datetime_usec)
  end

  def types, do: @types

  def changeset(image, attrs) do
    image
    |> cast(attrs, [:type, :local_path, :provider, :item_id])
    |> validate_required([:type, :item_id])
    |> validate_inclusion(:type, @types)
    |> foreign_key_constraint(:item_id)
    |> unique_constraint([:item_id, :type], name: :images_item_id_type_unique_index)
  end
end
