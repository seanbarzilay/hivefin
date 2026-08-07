defmodule Hivefin.Jellyfin.Dto.SessionTest do
  use Hivefin.DataCase, async: true

  alias Hivefin.Jellyfin.Dto.Session, as: SessionDto

  # Listed literally from jellyfin-sdk-kotlin SessionInfoDto — properties with
  # no default value. Never read from the implementation's own defaults.
  @required ~w(
    PlayableMediaTypes UserId LastActivityDate LastPlaybackCheckIn IsActive
    SupportsMediaControl SupportsRemoteControl HasCustomDeviceName SupportedCommands
  )

  setup do
    {:ok, user} =
      Hivefin.Accounts.create_user(%{
        name: "Sess",
        username: "sessdto",
        password: "password1",
        admin: true
      })

    {:ok, _token, access_token} =
      Hivefin.Accounts.issue_token(user, %{
        device_id: "dev",
        device_name: "Dev",
        client: "Jellyfin Web",
        client_version: "10.9.0"
      })

    {:ok, access_token: Hivefin.Repo.preload(access_token, :user)}
  end

  test "carries every required SessionInfoDto field, non-null", %{access_token: at} do
    dto = SessionDto.from_access_token(at)

    for key <- @required do
      assert Map.has_key?(dto, key), "SessionInfoDto missing required key #{key}"
      refute is_nil(dto[key]), "SessionInfoDto required key #{key} is null"
    end
  end

  test "required_keys/0 matches the SDK list", %{access_token: _at} do
    assert Enum.sort(SessionDto.required_keys()) == Enum.sort(@required)
  end

  test "LastPlaybackCheckIn is an ISO8601 timestamp", %{access_token: at} do
    dto = SessionDto.from_access_token(at)

    assert {:ok, _, _} = DateTime.from_iso8601(dto["LastPlaybackCheckIn"])
  end

  test "Id is the access token id", %{access_token: at} do
    dto = SessionDto.from_access_token(at)

    assert dto["Id"] == Hivefin.Jellyfin.Id.format(at.id)
  end
end
