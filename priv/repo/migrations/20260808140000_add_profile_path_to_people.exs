defmodule Hivefin.Repo.Migrations.AddProfilePathToPeople do
  use Ecto.Migration

  def change do
    alter table(:people) do
      add :profile_path, :text
    end
  end
end
