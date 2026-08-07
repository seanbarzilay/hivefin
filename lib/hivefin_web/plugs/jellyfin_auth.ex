defmodule HivefinWeb.Plugs.JellyfinAuth do
  @moduledoc """
  Resolves Jellyfin MediaBrowser authorization into `conn.assigns.current_user`.

  Accepts (in order):
  1. `X-Emby-Authorization` / `Authorization` MediaBrowser header with Token=
  2. Query `api_key` / `ApiKey` / `apiKey` (img tags, stream URLs, SDK getUri)
  """

  import Plug.Conn

  alias Hivefin.Accounts
  alias Hivefin.Accounts.User
  alias Hivefin.Jellyfin.Auth

  def init(opts), do: opts

  def call(conn, _opts) do
    conn = fetch_query_params(conn)

    case resolve_token(conn) do
      {:ok, token} ->
        case Accounts.get_access_token(token) do
          %{user: %User{} = user} = access_token ->
            conn
            |> assign(:current_user, user)
            |> assign(:current_access_token, access_token)

          _ ->
            unauthorized(conn)
        end

      :error ->
        unauthorized(conn)
    end
  end

  defp resolve_token(conn) do
    case header_token(conn) do
      {:ok, _} = ok -> ok
      :error -> query_api_key(conn)
    end
  end

  defp header_token(conn) do
    with header when is_binary(header) <- first_auth_header(conn),
         {:ok, parsed} <- Auth.parse_authorization(header),
         token when is_binary(token) and token != "" <- parsed.token do
      {:ok, token}
    else
      _ -> :error
    end
  end

  defp query_api_key(conn) do
    key =
      conn.query_params["api_key"] ||
        conn.query_params["ApiKey"] ||
        conn.query_params["apiKey"]

    if is_binary(key) and key != "", do: {:ok, key}, else: :error
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

  defp unauthorized(conn) do
    conn
    |> put_status(:unauthorized)
    |> Phoenix.Controller.json(%{"error" => "unauthorized"})
    |> halt()
  end
end
