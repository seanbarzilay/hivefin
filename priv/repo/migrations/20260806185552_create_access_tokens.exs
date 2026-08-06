defmodule Hivefin.Repo.Migrations.CreateAccessTokens do
  use Ecto.Migration

  def change do
    create table(:access_tokens, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :token, :string, null: false
      add :device_id, :string
      add :device_name, :string
      add :client, :string
      add :client_version, :string
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:access_tokens, [:token])
    create index(:access_tokens, [:user_id])
  end
end
