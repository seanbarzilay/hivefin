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

  # Listed literally from jellyfin-sdk-kotlin PlayerStateInfo — properties with
  # no default value. A missing one raises MissingFieldException client-side
  # and the whole session is discarded silently (same defect class as above).
  @play_state_required ~w(CanSeek IsPaused IsMuted RepeatMode PlaybackOrder)

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

  # Regression test for the jellyfin-web crash: it dereferences
  # `PlayState.IsPaused` unguarded on every Sessions push, so an idle session
  # without PlayState throws inside the socket dispatch chain — which also
  # carries the video player's events, so playback never starts in browser.
  test "an idle session still carries PlayState with all 5 required fields", %{
    access_token: at
  } do
    dto = SessionDto.from_access_token(at)
    play_state = dto["PlayState"]

    assert play_state, "expected PlayState to be present even when idle"

    for key <- @play_state_required do
      assert Map.has_key?(play_state, key), "PlayState missing required key #{key}"
      refute is_nil(play_state[key]), "PlayState required key #{key} is null"
    end

    assert play_state["CanSeek"] == false
    assert play_state["IsPaused"] == false
    assert play_state["IsMuted"] == false
    assert play_state["RepeatMode"] == "RepeatNone"
    assert play_state["PlaybackOrder"] == "Default"
    refute Map.has_key?(play_state, "PositionTicks")
  end

  test "omits NowPlayingItem when nothing is playing (NowPlayingItem only)", %{access_token: at} do
    dto = SessionDto.from_access_token(at)

    refute Map.has_key?(dto, "NowPlayingItem")
  end

  test "includes PlayState with all 5 required fields plus PositionTicks when playing", %{
    access_token: at
  } do
    dto =
      SessionDto.from_access_token(at,
        state: %{item_id: nil, position_ticks: 500, is_paused: true}
      )

    play_state = dto["PlayState"]

    for key <- @play_state_required do
      assert Map.has_key?(play_state, key), "PlayState missing required key #{key}"
      refute is_nil(play_state[key]), "PlayState required key #{key} is null"
    end

    assert play_state["PositionTicks"] == 500
    assert play_state["IsPaused"] == true
    assert play_state["CanSeek"] == true
    assert play_state["IsMuted"] == false
    assert play_state["RepeatMode"] == "RepeatNone"
    assert play_state["PlaybackOrder"] == "Default"
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
  # same omit-NowPlayingItem path as passing no state at all — but PlayState
  # is still present (idle shape), never omitted.
  test "omits NowPlayingItem for an all-nil state (stopped/2 shape); PlayState stays idle", %{
    access_token: at
  } do
    dto =
      SessionDto.from_access_token(at,
        state: %{item_id: nil, position_ticks: nil, is_paused: false}
      )

    refute Map.has_key?(dto, "NowPlayingItem")
    assert dto["PlayState"]["CanSeek"] == false
    assert dto["PlayState"]["IsPaused"] == false
    refute Map.has_key?(dto["PlayState"], "PositionTicks")
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

  # Pinned to [] on purpose: there is no command-delivery endpoint (Task 9
  # unbuilt), and advertising a command with nothing behind it gives clients
  # a control that silently does nothing when pressed. Do not populate this
  # list before Task 9 lands delivery for whatever it lists.
  test "supported_commands/0 is empty until Task 9 adds command delivery" do
    assert SessionDto.supported_commands() == []
  end

  test "a session with no live socket is not controllable", %{access_token: at} do
    dto = SessionDto.from_access_token(at)

    assert dto["SupportsMediaControl"] == false
    assert dto["SupportsRemoteControl"] == false
    assert dto["SupportedCommands"] == []
  end

  test "a controllable session reports addressable but advertises no commands", %{
    access_token: at
  } do
    dto = SessionDto.from_access_token(at, controllable: true)

    assert dto["SupportsMediaControl"] == true
    assert dto["SupportsRemoteControl"] == true
    assert dto["Capabilities"]["SupportsMediaControl"] == true
    # No commands to advertise until Task 9 adds delivery — see
    # supported_commands/0.
    assert dto["SupportedCommands"] == []
    assert dto["Capabilities"]["SupportedCommands"] == []
  end

  # Regression risk: the new :controllable option's map merge could clobber
  # or drop unrelated keys instead of only touching the 4 capability entries.
  test "controllable sessions still carry every required field, PlayState included", %{
    access_token: at
  } do
    dto = SessionDto.from_access_token(at, controllable: true)

    for key <- @required do
      assert Map.has_key?(dto, key), "missing #{key}"
      refute is_nil(dto[key]), "#{key} is null"
    end

    play_state = dto["PlayState"]
    assert play_state, "expected PlayState to be present even when controllable"

    for key <- @play_state_required do
      assert Map.has_key?(play_state, key), "PlayState missing #{key}"
      refute is_nil(play_state[key]), "PlayState #{key} is null"
    end
  end
end
