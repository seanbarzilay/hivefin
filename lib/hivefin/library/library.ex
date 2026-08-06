defmodule Hivefin.Library.Library do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "libraries" do
    field :name, :string
    field :type, Ecto.Enum, values: [:movies, :tv]
    field :path, :string
    field :last_scanned_at, :utc_datetime_usec

    has_many :items, Hivefin.Library.Item
    has_many :scan_jobs, Hivefin.Library.ScanJob

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(library, attrs) do
    library
    |> cast(attrs, [:name, :type, :path])
    |> validate_required([:name, :type, :path])
    |> update_change(:path, &Path.expand/1)
    |> validate_path_exists()
    |> unique_constraint(:path)
  end

  defp validate_path_exists(changeset) do
    case get_field(changeset, :path) do
      nil ->
        changeset

      path ->
        if File.dir?(path) do
          changeset
        else
          add_error(changeset, :path, "must be an existing directory")
        end
    end
  end
end
