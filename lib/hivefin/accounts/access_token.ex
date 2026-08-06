defmodule Hivefin.Accounts.AccessToken do
  use Ecto.Schema
  import Ecto.Changeset

  alias Hivefin.Accounts.User

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "access_tokens" do
    field :token, :string
    field :device_id, :string
    field :device_name, :string
    field :client, :string
    field :client_version, :string

    belongs_to :user, User

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Casts only client-supplied device metadata.

  Programmatic fields (`:user_id`, `:token`) must be set via `put_change/3`
  by the accounts context, not cast from attrs.
  """
  def changeset(access_token, attrs) do
    access_token
    |> cast(attrs, [:device_id, :device_name, :client, :client_version])
    |> validate_required([:device_id])
    |> unique_constraint(:token)
    |> foreign_key_constraint(:user_id)
  end
end
