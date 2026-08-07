defmodule HivefinWeb.Admin.UserController do
  use HivefinWeb, :controller

  alias Hivefin.Accounts

  def index(conn, _params) do
    render(conn, :index,
      page_title: "Users",
      active: :users,
      current_user: conn.assigns.current_admin,
      users: Accounts.list_users()
    )
  end

  def create(conn, %{"user" => params}) do
    name =
      case params["name"] do
        n when is_binary(n) and n != "" -> n
        _ -> params["username"]
      end

    attrs = %{
      name: name,
      username: params["username"],
      password: params["password"],
      admin: params["admin"] in ["true", "on", "1"]
    }

    case Accounts.create_user(attrs) do
      {:ok, user} ->
        conn
        |> put_flash(:info, "Created user “#{user.username}”.")
        |> redirect(to: ~p"/admin/users")

      {:error, changeset} ->
        conn
        |> put_flash(:error, format_errors(changeset))
        |> redirect(to: ~p"/admin/users")
    end
  end

  def reset_password(conn, %{"id" => id, "password" => password}) do
    case Accounts.get_user(id) do
      nil ->
        conn
        |> put_flash(:error, "User not found.")
        |> redirect(to: ~p"/admin/users")

      user ->
        case Accounts.set_password(user, password) do
          {:ok, _} ->
            conn
            |> put_flash(:info, "Password updated for “#{user.username}”.")
            |> redirect(to: ~p"/admin/users")

          {:error, changeset} ->
            conn
            |> put_flash(:error, format_errors(changeset))
            |> redirect(to: ~p"/admin/users")
        end
    end
  end

  def reset_password(conn, _params) do
    conn
    |> put_flash(:error, "Password is required.")
    |> redirect(to: ~p"/admin/users")
  end

  def delete(conn, %{"id" => id}) do
    case Accounts.get_user(id) do
      nil ->
        conn
        |> put_flash(:error, "User not found.")
        |> redirect(to: ~p"/admin/users")

      user ->
        if user.id == conn.assigns.current_admin.id do
          conn
          |> put_flash(:error, "You cannot delete the account you are signed in with.")
          |> redirect(to: ~p"/admin/users")
        else
          case Accounts.delete_user(user) do
            {:ok, _} ->
              conn
              |> put_flash(:info, "Deleted user “#{user.username}”.")
              |> redirect(to: ~p"/admin/users")

            {:error, :last_admin} ->
              conn
              |> put_flash(:error, "Cannot delete the last administrator.")
              |> redirect(to: ~p"/admin/users")

            {:error, _} ->
              conn
              |> put_flash(:error, "Could not delete user.")
              |> redirect(to: ~p"/admin/users")
          end
        end
    end
  end

  defp format_errors(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> Enum.map(fn {field, messages} -> "#{field} #{Enum.join(messages, ", ")}" end)
    |> Enum.join("; ")
  end
end
