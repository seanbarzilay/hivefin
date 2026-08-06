defmodule Hivefin.Repo.Migrations.CreateLibraryTables do
  use Ecto.Migration

  def change do
    create table(:libraries, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :type, :string, null: false
      add :path, :string, null: false
      add :last_scanned_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create index(:libraries, [:type])
    create unique_index(:libraries, [:path])

    create table(:items, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :type, :string, null: false
      add :name, :string, null: false
      add :sort_name, :string
      add :premiere_date, :date
      add :production_year, :integer
      add :index_number, :integer
      add :parent_index_number, :integer
      add :provider_ids, :map, null: false, default: %{}
      add :overview, :text

      add :library_id, references(:libraries, type: :binary_id, on_delete: :delete_all),
        null: false

      add :parent_id, references(:items, type: :binary_id, on_delete: :nilify_all)
      timestamps(type: :utc_datetime_usec)
    end

    create index(:items, [:library_id])
    create index(:items, [:type])
    create index(:items, [:parent_id])
    create index(:items, [:library_id, :type])

    create table(:media_sources, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :path, :string, null: false
      add :container, :string
      add :size, :bigint
      add :mtime, :utc_datetime_usec
      add :bitrate, :integer
      add :duration_ticks, :bigint
      add :item_id, references(:items, type: :binary_id, on_delete: :delete_all), null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:media_sources, [:path])
    create index(:media_sources, [:item_id])

    create table(:media_streams, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :index, :integer, null: false
      add :type, :string, null: false
      add :codec, :string
      add :language, :string
      add :channels, :integer
      add :width, :integer
      add :height, :integer
      add :bit_rate, :integer
      add :is_default, :boolean, null: false, default: false
      add :is_forced, :boolean, null: false, default: false
      add :title, :string

      add :media_source_id,
          references(:media_sources, type: :binary_id, on_delete: :delete_all),
          null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:media_streams, [:media_source_id])

    create table(:scan_jobs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :status, :string, null: false, default: "running"
      add :items_found, :integer, null: false, default: 0
      add :items_added, :integer, null: false, default: 0
      add :error, :text
      add :started_at, :utc_datetime_usec
      add :finished_at, :utc_datetime_usec

      add :library_id, references(:libraries, type: :binary_id, on_delete: :delete_all),
        null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:scan_jobs, [:library_id])
    create index(:scan_jobs, [:status])
  end
end
