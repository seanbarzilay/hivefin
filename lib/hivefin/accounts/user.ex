defmodule Hivefin.Accounts.User do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "users" do
    field :name, :string
    field :username, :string
    field :password, :string, virtual: true, redact: true
    field :password_hash, :string, redact: true
    field :admin, :boolean, default: false
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(user, attrs) do
    user
    |> cast(attrs, [:name, :username, :password, :admin])
    |> validate_required([:name, :username, :password])
    |> validate_length(:password, min: 8)
    |> unique_constraint(:username)
    |> hash_password()
  end

  @doc """
  Updates password only (admin reset / self-service).
  """
  def password_changeset(user, attrs) do
    user
    |> cast(attrs, [:password])
    |> validate_required([:password])
    |> validate_length(:password, min: 8)
    |> hash_password()
  end

  @doc """
  Updates non-password profile fields (name, admin flag).
  """
  def profile_changeset(user, attrs) do
    user
    |> cast(attrs, [:name, :admin])
    |> validate_required([:name])
  end

  defp hash_password(changeset) do
    case get_change(changeset, :password) do
      nil ->
        changeset

      pw ->
        changeset
        |> put_change(:password_hash, Argon2.hash_pwd_salt(pw))
        |> delete_change(:password)
    end
  end
end
