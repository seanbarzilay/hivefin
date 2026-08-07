defmodule HivefinWeb.Jellyfin.UserController do
  use HivefinWeb, :controller

  alias Hivefin.Accounts
  alias Hivefin.Jellyfin.Auth
  alias Hivefin.Jellyfin.Dto
  alias Hivefin.Jellyfin.SystemInfo

  def authenticate_by_name(conn, params) do
    # SDK may send flat {Username,Pw} or nested {authenticateUserByName: {...}}
    creds =
      case params do
        %{"authenticateUserByName" => nested} when is_map(nested) -> nested
        %{"AuthenticateUserByName" => nested} when is_map(nested) -> nested
        other -> other
      end

    username = creds["Username"] || creds["username"]
    password = creds["Pw"] || creds["Password"] || creds["pw"] || creds["password"]

    device_attrs = device_attrs_from_conn(conn)


    with true <- is_binary(username) and username != "",
         true <- is_binary(password),
         {:ok, user} <- Accounts.authenticate(username, password),
         {:ok, token, at} <- Accounts.issue_token(user, device_attrs) do
      json(conn, %{
        "User" => Dto.User.from_user(user),
        "AccessToken" => token,
        "ServerId" => Hivefin.Jellyfin.Id.format(SystemInfo.server_id()),
        "SessionInfo" => %{
          "Id" => Hivefin.Jellyfin.Id.format(at.id),
          "UserId" => Hivefin.Jellyfin.Id.format(user.id),
          "UserName" => user.name,
          "Client" => device_attrs[:client],
          "DeviceName" => device_attrs[:device_name],
          "DeviceId" => device_attrs[:device_id],
          "ApplicationVersion" => device_attrs[:client_version],
          "IsActive" => true,
          "ServerId" => Hivefin.Jellyfin.Id.format(SystemInfo.server_id())
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

  @doc """
  Public users list (unauthenticated). Hivefin has no public/anonymous users.
  Jellyfin Vue calls this after discovery.
  """
  def public_users(conn, _params) do
    json(conn, [])
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
