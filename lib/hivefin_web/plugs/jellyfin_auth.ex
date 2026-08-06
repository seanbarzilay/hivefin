defmodule HivefinWeb.Plugs.JellyfinAuth do
  @moduledoc """
  Resolves Jellyfin MediaBrowser authorization headers into `conn.assigns.current_user`.
  """

  import Plug.Conn

  alias Hivefin.Accounts
  alias Hivefin.Accounts.User
  alias Hivefin.Jellyfin.Auth

  def init(opts), do: opts

  def call(conn, _opts) do
    with header <- first_auth_header(conn),
         {:ok, parsed} <- Auth.parse_authorization(header),
         token when is_binary(token) <- parsed.token,
         %{user: %User{} = user} = access_token <- Accounts.get_access_token(token) do
      conn
      |> assign(:current_user, user)
      |> assign(:current_access_token, access_token)
    else
      _ ->
        conn
        |> put_status(:unauthorized)
        |> Phoenix.Controller.json(%{"error" => "unauthorized"})
        |> halt()
    end
  end

  defp first_auth_header(conn) do
    case get_req_header(conn, "x-emby-authorization") do
      [header | _] ->
        header

      [] ->
        case get_req_header(conn, "authorization") do
          [header | _] -> header
          [] -> nil
        end
    end
  end
end
