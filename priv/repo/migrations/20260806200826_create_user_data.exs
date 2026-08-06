defmodule Hivefin.Repo.Migrations.CreateUserData do
  use Ecto.Migration

  def change do
    create table(:user_data, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :playback_position_ticks, :bigint, null: false, default: 0
      add :played_percentage, :float, null: false, default: 0.0
      add :played, :boolean, null: false, default: false
      add :play_count, :integer, null: false, default: 0
      add :is_favorite, :boolean, null: false, default: false
      add :last_played_date, :utc_datetime_usec

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :item_id, references(:items, type: :binary_id, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:user_data, [:user_id, :item_id])
    create index(:user_data, [:item_id])
    create index(:user_data, [:user_id])
  end
end
