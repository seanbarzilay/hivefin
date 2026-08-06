defmodule Hivefin.Library.MediaSource do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "media_sources" do
    field :path, :string
    field :container, :string
    field :size, :integer
    field :mtime, :utc_datetime_usec
    field :bitrate, :integer
    field :duration_ticks, :integer

    belongs_to :item, Hivefin.Library.Item
    has_many :media_streams, Hivefin.Library.MediaStream

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(media_source, attrs) do
    media_source
    |> cast(attrs, [:path, :container, :size, :mtime, :bitrate, :duration_ticks, :item_id])
    |> validate_required([:path, :item_id])
    |> update_change(:path, &Path.expand/1)
    |> unique_constraint(:path)
    |> foreign_key_constraint(:item_id)
  end
end
