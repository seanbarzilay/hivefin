defmodule Hivefin.Jellyfin.Dto.SessionTest do
  use Hivefin.DataCase, async: true

  alias Hivefin.Jellyfin.Dto.Session, as: SessionDto
  alias Hivefin.Library.LibraryContext

  @movies_path Path.expand("test/support/fixtures/media_tree/movies", File.cwd!())

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

    {:ok, library} =
      LibraryContext.create_library(%{
        name: "Movies #{System.unique_integer([:positive])}",
        type: :movies,
        path: @movies_path
      })

    {:ok, movie, :created} =
      LibraryContext.find_or_create_movie(library.id, %{
        name: "Big Buck Bunny",
        production_year: 2008
      })

    {:ok, _} =
      %Hivefin.Library.MediaSource{}
      |> Hivefin.Library.MediaSource.changeset(%{
        path: Path.join(System.tmp_dir!(), "hivefin-sessdto-#{movie.id}.mp4"),
        container: "mp4",
        duration_ticks: 60_000_000,
        item_id: movie.id
      })
      |> Hivefin.Repo.insert()

    {:ok, access_token: Hivefin.Repo.preload(access_token, :user), movie: movie}
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

  test "omits NowPlayingItem when nothing is playing", %{access_token: at} do
    dto = SessionDto.from_access_token(at)

    refute Map.has_key?(dto, "NowPlayingItem")
    refute Map.has_key?(dto, "PlayState")
  end

  test "includes PlayState when a position is known", %{access_token: at} do
    dto =
      SessionDto.from_access_token(at,
        state: %{item_id: nil, position_ticks: 500, is_paused: true}
      )

    assert dto["PlayState"]["PositionTicks"] == 500
    assert dto["PlayState"]["IsPaused"] == true
    assert dto["PlayState"]["CanSeek"] == true
  end

  test "still carries every required field with state present", %{access_token: at} do
    dto =
      SessionDto.from_access_token(at,
        state: %{item_id: nil, position_ticks: 1, is_paused: false}
      )

    for key <- @required do
      assert Map.has_key?(dto, key), "missing #{key}"
      refute is_nil(dto[key]), "#{key} is null"
    end
  end

  # Minor 1: an all-nil state (exactly what stopped/2 records) must take the
  # same omit-both-keys path as passing no state at all, not insert nulls.
  test "omits NowPlayingItem/PlayState for an all-nil state (stopped/2 shape)", %{
    access_token: at
  } do
    dto =
      SessionDto.from_access_token(at,
        state: %{item_id: nil, position_ticks: nil, is_paused: false}
      )

    refute Map.has_key?(dto, "NowPlayingItem")
    refute Map.has_key?(dto, "PlayState")
  end

  # Important 2 + the dashless form clients actually send (Id.format strips
  # dashes for the wire) — this is the path that would silently break if
  # get_item/1 were used instead of get_item_with_sources/1, or if the id
  # guard rejected the dashless form.
  test "includes NowPlayingItem with RunTimeTicks for a dashless item id", %{
    access_token: at,
    movie: movie
  } do
    dashless = Hivefin.Jellyfin.Id.format(movie.id)

    dto =
      SessionDto.from_access_token(at,
        state: %{item_id: dashless, position_ticks: 500, is_paused: false}
      )

    assert dto["NowPlayingItem"]["Id"] == dashless
    refute is_nil(dto["NowPlayingItem"]["RunTimeTicks"])
  end

  test "includes NowPlayingItem with RunTimeTicks for the dashed item id", %{
    access_token: at,
    movie: movie
  } do
    dto =
      SessionDto.from_access_token(at,
        state: %{item_id: movie.id, position_ticks: 500, is_paused: false}
      )

    assert dto["NowPlayingItem"]["Id"] == Hivefin.Jellyfin.Id.format(movie.id)
    refute is_nil(dto["NowPlayingItem"]["RunTimeTicks"])
  end

  test "a garbage item id omits NowPlayingItem instead of raising", %{access_token: at} do
    dto =
      SessionDto.from_access_token(at,
        state: %{item_id: "../etc/passwd", position_ticks: 500, is_paused: false}
      )

    refute Map.has_key?(dto, "NowPlayingItem")
    assert dto["PlayState"]["PositionTicks"] == 500
  end
end
