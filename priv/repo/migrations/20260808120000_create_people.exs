defmodule Hivefin.Repo.Migrations.CreatePeople do
  use Ecto.Migration

  def change do
    create table(:people, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :text, null: false
      add :sort_name, :text
      add :provider_ids, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    # Dedup key is the TMDb person id specifically, not the name — two actors
    # genuinely share a name, and a bare-name key would merge them.
    # Rows with no Tmdb id extract to NULL, which Postgres never treats as
    # equal, so uncredited people can coexist.
    create unique_index(:people, ["(provider_ids->>'Tmdb')"], name: :people_tmdb_id_unique_index)
    create index(:people, [:sort_name])

    create table(:item_people, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :item_id, references(:items, type: :binary_id, on_delete: :delete_all), null: false
      add :person_id, references(:people, type: :binary_id, on_delete: :delete_all), null: false
      add :role, :text
      add :type, :string, null: false
      add :sort_order, :integer

      timestamps(type: :utc_datetime_usec)
    end

    # A person can appear twice on one item under different kinds (director AND
    # writer is common), so type is part of the key. role is too: an actor
    # occasionally plays two characters in one film.
    create unique_index(:item_people, [:item_id, :person_id, :type, :role],
             name: :item_people_unique_index
           )

    create index(:item_people, [:item_id])
    create index(:item_people, [:person_id])
  end
end
