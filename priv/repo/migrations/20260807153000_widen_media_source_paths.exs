defmodule Hivefin.Repo.Migrations.WidenMediaSourcePaths do
  use Ecto.Migration

  def change do
    # Nested library trees often exceed varchar(255)
    alter table(:media_sources) do
      modify :path, :text, from: :string
    end

    alter table(:images) do
      modify :local_path, :text, from: :string
    end
  end
end
