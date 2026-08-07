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

  # GeneralCommandType values hivefin can actually deliver. Advertising more
  # than this gives clients a control that silently does nothing — there is
  # no command-delivery endpoint at all yet (see Task 9).
  @supported_commands ~w(DisplayMessage SetVolume Mute Unmute ToggleMute)

  @doc "GeneralCommandType values hivefin can actually deliver."
  def supported_commands, do: @supported_commands

  # Properties jellyfin-sdk-kotlin declares on PlayerStateInfo with no default
  # value — same MissingFieldException risk as @required above. Unlike
  # SessionInfoDto, this nested object must be present on EVERY session, idle
  # or not: jellyfin-web dereferences `PlayState.IsPaused` with no null guard
  # on every Sessions push, so an idle session with no PlayState crashes the
  # client's socket dispatch chain (the same chain the video player's events
  # go through).
  @play_state_required %{
    "CanSeek" => false,
    "IsPaused" => false,
    "IsMuted" => false,
    "RepeatMode" => "RepeatNone",
    "PlaybackOrder" => "Default"
  }

  @doc """
  Builds a SessionInfoDto from an `AccessToken` (user should be preloaded).

  `opts[:state]` is `%{item_id: String.t() | nil, position_ticks: integer() | nil,
  is_paused: boolean()}`. `PlayState` is always present (idle values when there
  is nothing playing). `NowPlayingItem` is included only when `item_id`
  resolves to an item, and omitted otherwise.

  `opts[:controllable]` (default `false`) is whether this session holds a live
  socket right now. When true, `SupportsMediaControl`, `SupportsRemoteControl`,
  and `Capabilities.SupportsMediaControl` report `true` and `SupportedCommands`
  lists `supported_commands/0`.
  """
  def from_access_token(%AccessToken{} = at, opts \\ []) do
    user = at.user
    last_activity = datetime(at.updated_at || at.inserted_at) || now()
    state = Keyword.get(opts, :state)
    controllable? = Keyword.get(opts, :controllable, false)
    commands = if controllable?, do: @supported_commands, else: []

    %{
      "Id" => Hivefin.Jellyfin.Id.format(at.id),
      "UserId" => Hivefin.Jellyfin.Id.format(at.user_id),
      "UserName" => user_name(user),
      "Client" => at.client || "Unknown Client",
      "DeviceId" => at.device_id || "unknown",
      "DeviceName" => at.device_name || "Unknown Device",
      "ApplicationVersion" => at.client_version || "0.0.0",
      "IsActive" => true,
      "SupportsMediaControl" => controllable?,
      "SupportsRemoteControl" => controllable?,
      "HasCustomDeviceName" => false,
      "LastActivityDate" => last_activity,
      "LastPlaybackCheckIn" => last_activity,
      "ServerId" => Hivefin.Jellyfin.Id.format(Hivefin.Jellyfin.SystemInfo.server_id()),
      "PlayableMediaTypes" => ["Video"],
      "SupportedCommands" => commands,
      "Capabilities" => %{
        "PlayableMediaTypes" => ["Video"],
        "SupportedCommands" => commands,
        "SupportsMediaControl" => controllable?,
        "SupportsPersistentIdentifier" => true
      }
    }
    |> then(&Map.merge(@required, drop_nils(&1)))
    |> put_play_state(state)
  end

  defp drop_nils(map), do: map |> Enum.reject(fn {_k, v} -> is_nil(v) end) |> Map.new()

  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp user_name(%User{name: name}) when is_binary(name), do: name
  defp user_name(%User{username: username}) when is_binary(username), do: username
  defp user_name(_), do: nil

  defp datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp datetime(_), do: nil

  defp put_play_state(dto, state) do
    state = state || %{}
    position = Map.get(state, :position_ticks)
    item_id = Map.get(state, :item_id)
    paused = Map.get(state, :is_paused, false)

    dto
    |> Map.put("PlayState", play_state(position, paused))
    |> maybe_put("NowPlayingItem", now_playing_item(item_id))
  end

  defp play_state(nil, _paused), do: @play_state_required

  defp play_state(position, paused) when is_integer(position) do
    @play_state_required
    |> Map.merge(%{"CanSeek" => true, "IsPaused" => !!paused})
    |> Map.put("PositionTicks", position)
  end

  defp now_playing_item(nil), do: nil

  defp now_playing_item(item_id) when is_binary(item_id) do
    # Client-supplied id may be dashless (the wire format) or garbage; validate
    # with the same Id.normalize/1 the rest of the codebase uses before ever
    # querying — get_item_with_sources/1 would raise ArgumentError trying to
    # dump a non-UUID as :binary_id, which is fatal here (this runs inside the
    # socket's handle_info, not a request process).
    with {:ok, _} <- Hivefin.Jellyfin.Id.normalize(item_id),
         %{} = item <- Hivefin.Library.LibraryContext.get_item_with_sources(item_id) do
      Hivefin.Jellyfin.Dto.BaseItem.from_item(item)
    else
      _ -> nil
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
