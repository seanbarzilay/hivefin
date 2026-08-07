defmodule Hivefin.Repo.Migrations.WidenItemNames do
  use Ecto.Migration

  def change do
    # Scene/release folder names frequently exceed varchar(255)
    alter table(:items) do
      modify :name, :text, from: :string, null: false
      modify :sort_name, :text, from: :string
    end

    alter table(:libraries) do
      modify :path, :text, from: :string, null: false
      modify :name, :text, from: :string, null: false
    end

    alter table(:media_streams) do
      modify :title, :text, from: :string
      modify :codec, :text, from: :string
      modify :language, :text, from: :string
    end
  end
end
