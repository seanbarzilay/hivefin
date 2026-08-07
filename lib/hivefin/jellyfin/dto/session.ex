defmodule Hivefin.Jellyfin.Dto.Session do
  @moduledoc """
  Maps access tokens / device logins to Jellyfin SessionInfoDto-shaped maps.
  """

  alias Hivefin.Accounts.AccessToken
  alias Hivefin.Accounts.User

  # Properties jellyfin-sdk-kotlin declares on SessionInfoDto with no default
  # value: kotlinx.serialization requires the key to be present, and a missing
  # one makes the client discard the session silently.
  @required %{
    "PlayableMediaTypes" => ["Video"],
    "UserId" => nil,
    "LastActivityDate" => nil,
    "LastPlaybackCheckIn" => nil,
    "IsActive" => true,
    "SupportsMediaControl" => false,
    "SupportsRemoteControl" => false,
    "HasCustomDeviceName" => false,
    "SupportedCommands" => []
  }

  @doc "Required SessionInfoDto key names."
  def required_keys, do: Map.keys(@required)

  @doc """
  Builds a SessionInfoDto from an `AccessToken` (user should be preloaded).
  """
  def from_access_token(%AccessToken{} = at) do
    user = at.user
    last_activity = datetime(at.updated_at || at.inserted_at) || now()

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
      "LastActivityDate" => last_activity,
      "LastPlaybackCheckIn" => last_activity,
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
    |> then(&Map.merge(@required, drop_nils(&1)))
  end

  defp drop_nils(map), do: map |> Enum.reject(fn {_k, v} -> is_nil(v) end) |> Map.new()

  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp user_name(%User{name: name}) when is_binary(name), do: name
  defp user_name(%User{username: username}) when is_binary(username), do: username
  defp user_name(_), do: nil

  defp datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp datetime(_), do: nil
end
