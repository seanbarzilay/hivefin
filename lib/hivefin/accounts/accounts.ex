defmodule Hivefin.Accounts do
  @moduledoc """
  User accounts, authentication, access tokens, and admin bootstrap.
  """

  import Ecto.Query

  alias Hivefin.Repo
  alias Hivefin.Accounts.{AccessToken, User}

  def create_user(attrs) do
    %User{}
    |> User.changeset(attrs)
    |> Repo.insert()
  end

  def get_user(id), do: Repo.get(User, id)

  def count_users, do: Repo.aggregate(User, :count)

  def authenticate(username, password) do
    user = Repo.get_by(User, username: username)

    if user && Argon2.verify_pass(password, user.password_hash) do
      {:ok, user}
    else
      Argon2.no_user_verify()
      {:error, :invalid_credentials}
    end
  end

  @doc """
  Issues an opaque access token bound to the user and device metadata.

  Returns `{:ok, token_string, access_token}` on success.
  """
  def issue_token(%User{} = user, attrs) when is_map(attrs) do
    token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    %AccessToken{}
    |> AccessToken.changeset(Map.merge(attrs, %{user_id: user.id, token: token}))
    |> Repo.insert()
    |> case do
      {:ok, at} -> {:ok, token, at}
      err -> err
    end
  end

  @doc """
  Looks up the user for a valid access token string, or `nil`.
  """
  def get_user_by_token(token) when is_binary(token) do
    case Repo.get_by(AccessToken, token: token) do
      nil ->
        nil

      access_token ->
        access_token
        |> Repo.preload(:user)
        |> Map.fetch!(:user)
    end
  end

  def get_user_by_token(_), do: nil

  @doc """
  Revokes an access token by its string value.
  """
  def revoke_token(token) when is_binary(token) do
    case Repo.get_by(AccessToken, token: token) do
      nil -> {:error, :not_found}
      access_token -> Repo.delete(access_token)
    end
  end

  def bootstrap_admin do
    if count_users() > 0 do
      {:ok, Repo.one(from u in User, where: u.admin == true, limit: 1) || Repo.one(User)}
    else
      user = System.get_env("HIVEFIN_ADMIN_USER")
      pass = System.get_env("HIVEFIN_ADMIN_PASSWORD")

      if user in [nil, ""] or pass in [nil, ""] do
        {:error, :missing_bootstrap_env}
      else
        create_user(%{name: user, username: user, password: pass, admin: true})
      end
    end
  end
end
