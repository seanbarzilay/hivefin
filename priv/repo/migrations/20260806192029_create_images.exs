defmodule Hivefin.Repo.Migrations.CreateImages do
  use Ecto.Migration

  def change do
    create table(:images, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :type, :string, null: false
      add :local_path, :string
      add :provider, :string
      add :item_id, references(:items, type: :binary_id, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:images, [:item_id])
    create index(:images, [:item_id, :type])
  end
end
