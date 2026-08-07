defmodule HivefinWeb.Jellyfin.SocketController do
  @moduledoc """
  Authenticates `GET /socket` and upgrades it to the Jellyfin WebSocket protocol.

  Clients pass credentials as `api_key` or in the MediaBrowser auth header, so
  token resolution is shared with `JellyfinAuth` rather than reimplemented.
  """

  use HivefinWeb, :controller

  require Logger

  alias Hivefin.Accounts
  alias Hivefin.Accounts.AccessToken
  alias HivefinWeb.JellyfinSocket
  alias HivefinWeb.Plugs.JellyfinAuth

  @socket_timeout_ms 120_000

  def connect(conn, params) do
    with {:ok, token} <- JellyfinAuth.resolve_token(conn),
         %AccessToken{} = access_token <- Accounts.get_access_token(token) do
      log_device_mismatch(access_token, params)

      state = %{
        user_id: access_token.user_id,
        session_id: access_token.id,
        device_id: access_token.device_id,
        subscriptions: MapSet.new()
      }

      conn
      |> WebSockAdapter.upgrade(JellyfinSocket, state, timeout: @socket_timeout_ms)
      |> halt()
    else
      _ ->
        conn
        |> put_status(:unauthorized)
        |> json(%{"error" => "unauthorized"})
    end
  end

  # The token already identifies the device. A mismatch is worth noticing but
  # must never select the session — that would let a client address another's.
  defp log_device_mismatch(%AccessToken{device_id: device_id}, params) do
    claimed = params["deviceId"] || params["DeviceId"]

    if is_binary(claimed) and is_binary(device_id) and claimed != device_id do
      Logger.debug(
        "jellyfin socket: deviceId #{inspect(claimed)} != token device #{inspect(device_id)}"
      )
    end

    :ok
  end
end
