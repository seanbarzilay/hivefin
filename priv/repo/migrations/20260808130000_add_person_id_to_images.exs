defmodule Hivefin.Repo.Migrations.AddPersonIdToImages do
  use Ecto.Migration

  def change do
    alter table(:images) do
      add :person_id, references(:people, type: :binary_id, on_delete: :delete_all)
      modify :item_id, :binary_id, null: true, from: {:binary_id, null: false}
    end

    create index(:images, [:person_id])
    create unique_index(:images, [:person_id, :type], name: :images_person_id_type_unique_index)

    # Exactly one owner. Keeping this in the database means application code
    # cannot drift from the invariant. ~14.5k existing rows all have item_id
    # set and person_id NULL, so a plain (validating) constraint is cheap
    # here — no NOT VALID/VALIDATE dance needed at this table size.
    create constraint(:images, :images_one_owner,
             check:
               "(item_id IS NOT NULL AND person_id IS NULL) OR (item_id IS NULL AND person_id IS NOT NULL)"
           )
  end
end
