defmodule Hivefin.Jellyfin.Dto.User do
  @moduledoc """
  Maps domain users to Jellyfin UserDto-shaped JSON maps.
  """

  alias Hivefin.Accounts.User

  @doc """
  Builds a minimal UserDto map for API responses.
  """
  def from_user(%User{} = user) do
    %{
      "Name" => user.name,
      "Id" => Hivefin.Jellyfin.Id.format(user.id),
      "ServerId" => Hivefin.Jellyfin.Id.format(Hivefin.Jellyfin.SystemInfo.server_id()),
      "HasPassword" => true,
      "HasConfiguredPassword" => true,
      "HasConfiguredEasyPassword" => false,
      "EnableAutoLogin" => false,
      "LastLoginDate" => nil,
      "LastActivityDate" => nil,
      "Configuration" => %{},
      "Policy" => %{
        "IsAdministrator" => user.admin,
        "IsHidden" => false,
        "IsDisabled" => false,
        "EnableAllFolders" => true,
        "EnableRemoteAccess" => true
      }
    }
  end
end
