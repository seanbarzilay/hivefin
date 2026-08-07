defmodule HivefinWeb.JellyfinSocketTest do
  use Hivefin.DataCase, async: false

  alias HivefinWeb.JellyfinSocket

  defp state do
    %{
      user_id: Ecto.UUID.generate(),
      session_id: Ecto.UUID.generate(),
      device_id: "pixel",
      subscriptions: MapSet.new()
    }
  end

  defp frame(map), do: {Jason.encode!(map), [opcode: :text]}

  defp create_movie_with_source! do
    n = System.unique_integer([:positive])

    {:ok, library} =
      Hivefin.Library.LibraryContext.create_library(%{
        name: "Sock Movies #{n}",
        type: :movies,
        path: Path.expand("test/support/fixtures/media_tree/movies", File.cwd!())
      })

    {:ok, movie, :created} =
      Hivefin.Library.LibraryContext.find_or_create_movie(library.id, %{
        name: "Big Buck Bunny",
        production_year: 2008
      })

    {:ok, _} =
      %Hivefin.Library.MediaSource{}
      |> Hivefin.Library.MediaSource.changeset(%{
        path: Path.join(System.tmp_dir!(), "hivefin-sock-#{movie.id}.mp4"),
        container: "mp4",
        duration_ticks: 60_000_000,
        item_id: movie.id
      })
      |> Hivefin.Repo.insert()

    movie
  end

  defp persisted_state do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Hivefin.Accounts.create_user(%{
        name: "Sock",
        username: "sockuser#{n}",
        password: "password1",
        admin: true
      })

    {:ok, _token, at} =
      Hivefin.Accounts.issue_token(user, %{
        device_id: "dev-#{n}",
        device_name: "Dev",
        client: "Jellyfin Web",
        client_version: "10.9.0"
      })

    %{
      user_id: user.id,
      session_id: at.id,
      device_id: "dev-#{n}",
      subscriptions: MapSet.new(),
      user: user
    }
  end

  test "init pushes ForceKeepAlive so the client starts its keepalive timer" do
    assert {:push, {:text, json}, _state} = JellyfinSocket.init(state())

    decoded = Jason.decode!(json)
    assert decoded["MessageType"] == "ForceKeepAlive"
    assert is_integer(decoded["Data"])
    assert decoded["MessageId"]
  end

  test "KeepAlive is echoed" do
    assert {:push, {:text, json}, _state} =
             JellyfinSocket.handle_in(frame(%{"MessageType" => "KeepAlive"}), state())

    assert Jason.decode!(json)["MessageType"] == "KeepAlive"
  end

  test "unknown MessageType is ignored without closing the socket" do
    s = state()

    assert {:ok, ^s} =
             JellyfinSocket.handle_in(frame(%{"MessageType" => "TotallyMadeUp"}), s)
  end

  test "malformed JSON is ignored without closing the socket" do
    s = state()

    assert {:ok, ^s} = JellyfinSocket.handle_in({"{not json", [opcode: :text]}, s)
  end

  test "a message with no MessageType is ignored" do
    s = state()

    assert {:ok, ^s} = JellyfinSocket.handle_in(frame(%{"Data" => "x"}), s)
  end

  test "binary frames are ignored" do
    s = state()

    assert {:ok, ^s} = JellyfinSocket.handle_in({<<0, 1, 2>>, [opcode: :binary]}, s)
  end

  test "no-op subscription messages are accepted" do
    for type <- [
          "ActivityLogEntryStart",
          "ActivityLogEntryStop",
          "ScheduledTasksInfoStart",
          "ScheduledTasksInfoStop"
        ] do
      s = state()
      assert {:ok, ^s} = JellyfinSocket.handle_in(frame(%{"MessageType" => type}), s)
    end
  end

  test "an arbitrary handle_info message does not crash the socket" do
    s = state()
    assert {:ok, ^s} = JellyfinSocket.handle_info(:some_unexpected_message, s)
  end

  test "terminate returns :ok" do
    assert :ok = JellyfinSocket.terminate(:remote, state())
  end

  describe "session registration and Sessions push" do
    test "init registers the socket so it appears in Sessions.list/0" do
      s = state()

      assert {:push, _frame, _state} = JellyfinSocket.init(s)

      assert Enum.any?(Hivefin.Sessions.list(), &(&1.session_id == s.session_id))
    end

    test "SessionsStart pushes a Sessions message and records the subscription" do
      s = persisted_state()
      {:push, _, s} = JellyfinSocket.init(s)

      assert {:push, {:text, json}, new_state} =
               JellyfinSocket.handle_in(
                 frame(%{"MessageType" => "SessionsStart", "Data" => "0,1500"}),
                 s
               )

      decoded = Jason.decode!(json)
      assert decoded["MessageType"] == "Sessions"
      assert is_list(decoded["Data"])
      assert decoded["Data"] != []
      assert MapSet.member?(new_state.subscriptions, "Sessions")
    end

    test "SessionsStop clears the subscription" do
      s = state()
      {:push, _, s} = JellyfinSocket.init(s)
      {:push, _, s} = JellyfinSocket.handle_in(frame(%{"MessageType" => "SessionsStart"}), s)

      assert {:ok, new_state} =
               JellyfinSocket.handle_in(frame(%{"MessageType" => "SessionsStop"}), s)

      refute MapSet.member?(new_state.subscriptions, "Sessions")
    end

    test "a jellyfin_push message is forwarded to the client verbatim" do
      s = state()

      assert {:push, {:text, json}, ^s} =
               JellyfinSocket.handle_info(
                 {:jellyfin_push, %{"MessageType" => "Play", "MessageId" => "x"}},
                 s
               )

      assert Jason.decode!(json)["MessageType"] == "Play"
    end

    test "sessions_changed pushes Sessions only when subscribed" do
      s = state()

      # Not subscribed: no push.
      assert {:ok, ^s} = JellyfinSocket.handle_info(:sessions_changed, s)

      subscribed = %{s | subscriptions: MapSet.new(["Sessions"])}

      assert {:push, {:text, json}, _} =
               JellyfinSocket.handle_info(:sessions_changed, subscribed)

      assert Jason.decode!(json)["MessageType"] == "Sessions"
    end

    # Listed literally (not via Dto.Session.required_keys/0) so this test can
    # actually catch a regression in the required-keys list itself, not just
    # in whether sessions_message/1 applies it.
    @required_session_keys ~w(
      PlayableMediaTypes UserId LastActivityDate LastPlaybackCheckIn IsActive
      SupportsMediaControl SupportsRemoteControl HasCustomDeviceName SupportedCommands
    )

    test "every session in a Sessions push carries the required fields" do
      s = persisted_state()
      {:push, _, s} = JellyfinSocket.init(s)

      {:push, {:text, json}, _} =
        JellyfinSocket.handle_in(frame(%{"MessageType" => "SessionsStart"}), s)

      sessions = Jason.decode!(json)["Data"]
      # Without this the for-loop below can pass vacuously on an empty list.
      assert sessions != [], "expected at least one session in the Sessions push"

      for session <- sessions, key <- @required_session_keys do
        assert Map.has_key?(session, key), "SessionInfoDto missing #{key}"
        refute is_nil(session[key]), "SessionInfoDto #{key} is null"
      end
    end

    test "sessions_message excludes an access token with no live socket" do
      s = persisted_state()

      # A second access token for the same user that never opens a socket —
      # exactly the "146 dead rows" shape from the production regression.
      {:ok, _dead_token, dead_at} =
        Hivefin.Accounts.issue_token(s.user, %{
          device_id: "dead-device",
          device_name: "Dead",
          client: "Old Client",
          client_version: "1.0"
        })

      {:push, _, s} = JellyfinSocket.init(s)

      {:push, {:text, json}, _} =
        JellyfinSocket.handle_in(frame(%{"MessageType" => "SessionsStart"}), s)

      ids = Jason.decode!(json)["Data"] |> Enum.map(& &1["Id"])
      assert ids != [], "expected at least one live session in the Sessions push"

      assert Hivefin.Jellyfin.Id.format(s.session_id) in ids
      refute Hivefin.Jellyfin.Id.format(dead_at.id) in ids
    end

    test "duplicate registry entries for one session_id yield exactly one payload entry" do
      s = persisted_state()
      {:push, _, s} = JellyfinSocket.init(s)

      test_pid = self()

      dup =
        spawn(fn ->
          :ok =
            Hivefin.Sessions.register(s.session_id, %{
              user_id: s.user_id,
              device_id: s.device_id
            })

          send(test_pid, :dup_registered)
          Process.sleep(:infinity)
        end)

      assert_receive :dup_registered
      assert length(Hivefin.Sessions.pids(s.session_id)) == 2

      {:push, {:text, json}, _} =
        JellyfinSocket.handle_in(frame(%{"MessageType" => "SessionsStart"}), s)

      sessions = Jason.decode!(json)["Data"]
      assert sessions != [], "expected at least one session in the Sessions push"

      matches =
        Enum.filter(sessions, &(&1["Id"] == Hivefin.Jellyfin.Id.format(s.session_id)))

      assert length(matches) == 1,
             "expected exactly one entry for a duplicated session_id, got #{length(matches)}"

      Process.exit(dup, :kill)
    end

    test "a session_state message updates the registry entry" do
      s = state()
      {:push, _, s} = JellyfinSocket.init(s)

      assert {:ok, ^s} =
               JellyfinSocket.handle_info(
                 {:jellyfin_session_state, %{position_ticks: 999, is_paused: true}},
                 s
               )

      entry = Enum.find(Hivefin.Sessions.list(), &(&1.session_id == s.session_id))
      assert entry.position_ticks == 999
      assert entry.is_paused == true
    end

    # Important 3: exercises the real wiring end to end — the registry write
    # via put_state/2 sent from another process (as a controller would), the
    # live[at.id] join in sessions_message/1, and the NowPlayingItem lookup —
    # rather than stopping at the registry as the previous test did.
    test "put_state/2 from another process flows through to the Sessions push" do
      movie = create_movie_with_source!()

      s = persisted_state()
      {:push, _, s} = JellyfinSocket.init(s)

      # A controller runs in a request process, not the socket process — send
      # from a spawned task so this exercises the cross-process message path
      # put_state/2 actually uses, not a same-process shortcut.
      Task.async(fn ->
        Hivefin.Sessions.put_state(s.session_id, %{
          item_id: Hivefin.Jellyfin.Id.format(movie.id),
          position_ticks: 500,
          is_paused: false
        })
      end)
      |> Task.await()

      assert_receive {:jellyfin_session_state, attrs}
      assert {:ok, s} = JellyfinSocket.handle_info({:jellyfin_session_state, attrs}, s)

      {:push, {:text, json}, _} =
        JellyfinSocket.handle_in(frame(%{"MessageType" => "SessionsStart"}), s)

      sessions = Jason.decode!(json)["Data"]
      assert sessions != [], "expected at least one session in the Sessions push"

      session = Enum.find(sessions, &(&1["Id"] == Hivefin.Jellyfin.Id.format(s.session_id)))
      assert session, "expected a session entry for #{s.session_id}"

      assert session["PlayState"]["PositionTicks"] == 500
      assert session["PlayState"]["IsPaused"] == false
      refute is_nil(session["NowPlayingItem"])
      refute is_nil(session["NowPlayingItem"]["RunTimeTicks"])
    end
  end
end
