defmodule HivefinWeb.Plugs.AdminAuth do
  @moduledoc """
  Ensures the browser session has a logged-in admin user for `/admin/*`.
  """
  import Plug.Conn
  import Phoenix.Controller

  alias Hivefin.Accounts
  alias Hivefin.Accounts.User

  def init(opts), do: opts

  def call(conn, _opts) do
    user_id = get_session(conn, :admin_user_id)

    case user_id && Accounts.get_user(user_id) do
      %User{admin: true} = user ->
        assign(conn, :current_admin, user)

      %User{} ->
        conn
        |> configure_session(drop: true)
        |> put_flash(:error, "Administrator access required.")
        |> redirect(to: "/admin/login")
        |> halt()

      _ ->
        conn
        |> put_flash(:error, "Please log in.")
        |> redirect(to: "/admin/login")
        |> halt()
    end
  end
end
