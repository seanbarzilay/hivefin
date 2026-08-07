defmodule HivefinWeb.Admin.SessionController do
  use HivefinWeb, :controller

  alias Hivefin.Accounts
  alias Hivefin.Accounts.User

  def new(conn, _params) do
    if get_session(conn, :admin_user_id) do
      redirect(conn, to: ~p"/admin")
    else
      render(conn, :new, page_title: "Admin login")
    end
  end

  def create(conn, %{"username" => username, "password" => password}) do
    case Accounts.authenticate(username, password) do
      {:ok, %User{admin: true} = user} ->
        conn
        |> renew_session()
        |> put_session(:admin_user_id, user.id)
        |> put_flash(:info, "Welcome, #{user.username}.")
        |> redirect(to: ~p"/admin")

      {:ok, %User{}} ->
        conn
        |> put_flash(:error, "This account is not an administrator.")
        |> redirect(to: ~p"/admin/login")

      {:error, _} ->
        conn
        |> put_flash(:error, "Invalid username or password.")
        |> redirect(to: ~p"/admin/login")
    end
  end

  def create(conn, _params) do
    conn
    |> put_flash(:error, "Username and password are required.")
    |> redirect(to: ~p"/admin/login")
  end

  def delete(conn, _params) do
    conn
    |> renew_session()
    |> put_flash(:info, "Logged out.")
    |> redirect(to: ~p"/admin/login")
  end

  defp renew_session(conn) do
    conn
    |> configure_session(renew: true)
    |> clear_session()
  end
end
