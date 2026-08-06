defmodule Hivefin.Library.ScanJob do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "scan_jobs" do
    field :status, Ecto.Enum, values: [:running, :completed, :failed, :cancelled]
    field :items_found, :integer, default: 0
    field :items_added, :integer, default: 0
    field :error, :string
    field :started_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec

    belongs_to :library, Hivefin.Library.Library

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(scan_job, attrs) do
    scan_job
    |> cast(attrs, [
      :status,
      :items_found,
      :items_added,
      :error,
      :started_at,
      :finished_at,
      :library_id
    ])
    |> validate_required([:status, :library_id])
    |> foreign_key_constraint(:library_id)
  end
end
