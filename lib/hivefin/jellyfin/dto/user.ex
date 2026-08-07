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
      # jellyfin-web reads Configuration after GET /Users/:id; empty map leaves
      # home sections/preferences undefined and yields a blank Home shell.
      "Configuration" => default_configuration(),
      "Policy" => %{
        "IsAdministrator" => user.admin,
        "IsHidden" => false,
        "IsDisabled" => false,
        "EnableAllFolders" => true,
        "EnableRemoteAccess" => true,
        "EnableMediaPlayback" => true,
        "EnableAudioPlaybackTranscoding" => true,
        "EnableVideoPlaybackTranscoding" => true,
        "EnablePlaybackRemuxing" => true,
        "EnableContentDeletion" => false,
        "EnableContentDownloading" => true,
        "EnableSyncTranscoding" => true,
        "EnableMediaConversion" => false,
        "EnableRemoteControlOfOtherUsers" => user.admin,
        "EnableSharedDeviceControl" => true,
        "EnableRemoteControlOfSharedDevices" => true,
        "EnableLiveTvManagement" => false,
        "EnableLiveTvAccess" => false,
        "EnableUserPreferenceAccess" => true
      }
    }
  end

  defp default_configuration do
    %{
      "PlayDefaultAudioTrack" => true,
      "PlayDefaultSubtitleTrack" => false,
      "SubtitleLanguagePreference" => "",
      "AudioLanguagePreference" => "",
      "DisplayMissingEpisodes" => false,
      "GroupedFolders" => [],
      "SubtitleMode" => "Default",
      "DisplayCollectionsView" => false,
      "EnableLocalPassword" => false,
      "OrderedViews" => [],
      "LatestItemsExcludes" => [],
      "MyMediaExcludes" => [],
      "HidePlayedInLatest" => true,
      "RememberAudioSelections" => true,
      "RememberSubtitleSelections" => true,
      "EnableNextEpisodeAutoPlay" => true
    }
  end
end
