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
      # Android TV kotlinx.serialization requires SessionInfoDto fields that
      # the previous stub omitted (PlayableMediaTypes, LastActivityDate, …).
      session = Dto.Session.from_access_token(%{at | user: user})

      json(conn, %{
        "User" => Dto.User.from_user(user),
        "AccessToken" => token,
        "ServerId" => Hivefin.Jellyfin.Id.format(SystemInfo.server_id()),
        "SessionInfo" => session
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
  `GET /Users/:user_id` — jellyfin-web loads this right after login.

  Without it the shell renders blank Home/Favorites (client retries ~5× then gives up).
  """
  def show(conn, %{"user_id" => user_id}) do
    current = conn.assigns.current_user
    current_fmt = Hivefin.Jellyfin.Id.format(current.id)
    requested_fmt =
      user_id
      |> to_string()
      |> String.replace("-", "")
      |> String.downcase()

    cond do
      requested_fmt == current_fmt ->
        json(conn, Dto.User.from_user(current))

      current.admin ->
        case resolve_user(user_id) do
          %Hivefin.Accounts.User{} = user ->
            json(conn, Dto.User.from_user(user))

          nil ->
            conn
            |> put_status(:not_found)
            |> json(%{"error" => "not_found"})
        end

      true ->
        conn
        |> put_status(:not_found)
        |> json(%{"error" => "not_found"})
    end
  end

  @doc """
  Public users list (unauthenticated) for the login user picker.

  Returns non-hidden users (Hivefin has no hide flag yet — all users).
  Passwords are never included (`Dto.User` already omits secrets).
  """
  def public_users(conn, _params) do
    users =
      Accounts.list_users()
      |> Enum.map(&Dto.User.from_user/1)

    json(conn, users)
  end

  defp resolve_user(user_id) do
    case Hivefin.Jellyfin.Id.normalize(user_id) do
      {:ok, dashed} -> Accounts.get_user(dashed)
      :error -> Accounts.get_user(user_id)
    end
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
