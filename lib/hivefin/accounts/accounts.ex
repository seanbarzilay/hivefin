defmodule Hivefin.Accounts do
  @moduledoc """
  User accounts, authentication, and admin bootstrap.
  """

  import Ecto.Query

  alias Hivefin.Repo
  alias Hivefin.Accounts.User

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
