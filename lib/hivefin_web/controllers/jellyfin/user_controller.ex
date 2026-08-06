defmodule HivefinWeb.Jellyfin.UserController do
  use HivefinWeb, :controller

  alias Hivefin.Accounts
  alias Hivefin.Jellyfin.Auth
  alias Hivefin.Jellyfin.Dto
  alias Hivefin.Jellyfin.SystemInfo

  def authenticate_by_name(conn, params) do
    username = params["Username"] || params["username"]
    password = params["Pw"] || params["Password"] || params["pw"] || params["password"]

    device_attrs = device_attrs_from_conn(conn)

    with true <- is_binary(username) and username != "",
         true <- is_binary(password),
         {:ok, user} <- Accounts.authenticate(username, password),
         {:ok, token, at} <- Accounts.issue_token(user, device_attrs) do
      json(conn, %{
        "User" => Dto.User.from_user(user),
        "AccessToken" => token,
        "ServerId" => SystemInfo.server_id(),
        "SessionInfo" => %{
          "Id" => at.id,
          "UserId" => user.id,
          "UserName" => user.name,
          "Client" => device_attrs[:client],
          "DeviceName" => device_attrs[:device_name],
          "DeviceId" => device_attrs[:device_id],
          "ApplicationVersion" => device_attrs[:client_version],
          "IsActive" => true,
          "ServerId" => SystemInfo.server_id()
        }
      })
    else
      {:error, :invalid_credentials} ->
        conn
        |> put_status(:unauthorized)
        |> json(%{"error" => "invalid_credentials"})

      _ ->
        conn
        |> put_status(:bad_request)
        |> json(%{"error" => "invalid_request"})
    end
  end

  def me(conn, _params) do
    user = conn.assigns.current_user
    json(conn, Dto.User.from_user(user))
  end

  defp device_attrs_from_conn(conn) do
    header =
      case get_req_header(conn, "x-emby-authorization") do
        [h | _] -> h
        [] -> List.first(get_req_header(conn, "authorization"))
      end

    case Auth.parse_authorization(header) do
      {:ok, parsed} ->
        %{
          device_id: parsed.device_id || "unknown",
          device_name: parsed.device || "Unknown Device",
          client: parsed.client || "Unknown Client",
          client_version: parsed.version || "0.0.0"
        }

      {:error, _} ->
        %{
          device_id: "unknown",
          device_name: "Unknown Device",
          client: "Unknown Client",
          client_version: "0.0.0"
        }
    end
  end
end
