defmodule Hivefin.Library.Item do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "items" do
    field :type, Ecto.Enum, values: [:movie, :series, :season, :episode]
    field :name, :string
    field :sort_name, :string
    field :premiere_date, :date
    field :production_year, :integer
    field :index_number, :integer
    field :parent_index_number, :integer
    field :provider_ids, :map, default: %{}
    field :overview, :string

    belongs_to :library, Hivefin.Library.Library
    belongs_to :parent, __MODULE__
    has_many :children, __MODULE__, foreign_key: :parent_id
    has_many :media_sources, Hivefin.Library.MediaSource

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(item, attrs) do
    item
    |> cast(attrs, [
      :type,
      :name,
      :sort_name,
      :premiere_date,
      :production_year,
      :index_number,
      :parent_index_number,
      :provider_ids,
      :overview,
      :library_id,
      :parent_id
    ])
    |> validate_required([:type, :name, :library_id])
    |> maybe_default_sort_name()
    |> foreign_key_constraint(:library_id)
    |> foreign_key_constraint(:parent_id)
  end

  defp maybe_default_sort_name(changeset) do
    case {get_field(changeset, :sort_name), get_field(changeset, :name)} do
      {nil, name} when is_binary(name) ->
        put_change(changeset, :sort_name, String.downcase(name))

      _ ->
        changeset
    end
  end
end
