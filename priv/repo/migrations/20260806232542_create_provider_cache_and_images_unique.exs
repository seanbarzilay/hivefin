defmodule Hivefin.Repo.Migrations.CreateProviderCacheAndImagesUnique do
  use Ecto.Migration

  def change do
    create table(:provider_cache, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :provider, :string, null: false
      add :cache_key, :string, null: false
      add :payload, :map, null: false, default: %{}
      add :expires_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:provider_cache, [:provider, :cache_key])
    create index(:provider_cache, [:expires_at])

    # Ensure one image row per type per item (existing index is non-unique).
    create unique_index(:images, [:item_id, :type], name: :images_item_id_type_unique_index)
  end
end
