defmodule Hivefin.Library.MediaStream do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "media_streams" do
    field :index, :integer
    field :type, Ecto.Enum, values: [:video, :audio, :subtitle]
    field :codec, :string
    field :language, :string
    field :channels, :integer
    field :width, :integer
    field :height, :integer
    field :bit_rate, :integer
    field :is_default, :boolean, default: false
    field :is_forced, :boolean, default: false
    field :title, :string

    belongs_to :media_source, Hivefin.Library.MediaSource

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(media_stream, attrs) do
    media_stream
    |> cast(attrs, [
      :index,
      :type,
      :codec,
      :language,
      :channels,
      :width,
      :height,
      :bit_rate,
      :is_default,
      :is_forced,
      :title,
      :media_source_id
    ])
    |> validate_required([:index, :type, :media_source_id])
    |> foreign_key_constraint(:media_source_id)
  end
end
