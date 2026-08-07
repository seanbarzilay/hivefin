defmodule Hivefin.Jellyfin.Dto.Session do
  @moduledoc """
  Maps access tokens / device logins to Jellyfin SessionInfoDto-shaped maps.
  """

  alias Hivefin.Accounts.AccessToken
  alias Hivefin.Accounts.User

  @doc """
  Builds a SessionInfoDto from an `AccessToken` (user should be preloaded).
  """
  def from_access_token(%AccessToken{} = at) do
    user = at.user

    %{
      "Id" => Hivefin.Jellyfin.Id.format(at.id),
      "UserId" => Hivefin.Jellyfin.Id.format(at.user_id),
      "UserName" => user_name(user),
      "Client" => at.client || "Unknown Client",
      "DeviceId" => at.device_id || "unknown",
      "DeviceName" => at.device_name || "Unknown Device",
      "ApplicationVersion" => at.client_version || "0.0.0",
      "IsActive" => true,
      "SupportsMediaControl" => false,
      "SupportsRemoteControl" => false,
      "HasCustomDeviceName" => false,
      "LastActivityDate" => datetime(at.updated_at || at.inserted_at),
      "ServerId" => Hivefin.Jellyfin.Id.format(Hivefin.Jellyfin.SystemInfo.server_id()),

      "PlayableMediaTypes" => ["Video"],
      "SupportedCommands" => [],
      "Capabilities" => %{
        "PlayableMediaTypes" => ["Video"],
        "SupportedCommands" => [],
        "SupportsMediaControl" => false,
        "SupportsPersistentIdentifier" => true
      }
    }
  end

  defp user_name(%User{name: name}) when is_binary(name), do: name
  defp user_name(%User{username: username}) when is_binary(username), do: username
  defp user_name(_), do: nil

  defp datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp datetime(_), do: nil
end
