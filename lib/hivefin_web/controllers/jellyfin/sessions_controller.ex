defmodule HivefinWeb.Jellyfin.SessionsController do
  @moduledoc """
  Jellyfin sessions listing, capability stubs, and progress reporting.
  """

  use HivefinWeb, :controller

  alias Hivefin.Jellyfin.Dto.Session, as: SessionDto
  alias Hivefin.Jellyfin.Id
  alias Hivefin.Jellyfin.WsCommand
  alias Hivefin.Library.{LibraryContext, UserData}
  alias Hivefin.Sessions

  # Query params JellyfinAuth reads a token from (see resolve_token/1) — never
  # forward these into a GeneralCommand's Arguments, or the caller's own
  # credential rides along to the target device.
  @credential_params ~w(api_key ApiKey apiKey)

  # Jellyfin-compatible: past this fraction of runtime, treat as finished
  # (clears resume / shows watched). Vue only sends PositionTicks, never Played.
  @completion_ratio 0.90

  @doc """
  `GET /Sessions` — live device sessions for the current user (only access
  tokens that currently hold a websocket, matching the Sessions socket push).
  """
  def index(conn, params) do
    device_id = blank_to_nil(params["deviceId"] || params["DeviceId"])
    user = conn.assigns.current_user

    sessions =
      user.id
      |> Sessions.live_for_user(device_id: device_id)
      |> Enum.map(fn {at, play_state} ->
        # controllable: true is unconditional, not per-entry, because
        # live_for_user/2 only ever returns access tokens with a live socket
        # — every entry here is controllable by definition, same condition
        # the Sessions websocket push (sessions_message/1) uses. If
        # live_for_user/2 is ever widened to include sessions without a live
        # socket, this becomes wrong silently; re-derive controllable per-entry
        # then.
        SessionDto.from_access_token(at, state: play_state, controllable: true)
      end)

    json(conn, sessions)
  end

  @doc """
  `POST /Sessions/Capabilities` — accept capability report (no-op).
  """
  def capabilities(conn, _params) do
    conn
    |> put_status(:no_content)
    |> send_resp(:no_content, "")
  end

  @doc """
  `POST /Sessions/Capabilities/Full` — accept full capability body (no-op).
  """
  def capabilities_full(conn, _params) do
    conn
    |> put_status(:no_content)
    |> send_resp(:no_content, "")
  end

  @doc """
  `POST /Sessions/Playing` — client started playback.
  """
  def playing(conn, params) do
    record_session_state(conn, %{
      item_id: params["ItemId"] || params["itemId"] || params["item_id"],
      position_ticks: parse_int(params["PositionTicks"] || params["positionTicks"]),
      is_paused: false
    })

    report(conn, params, :playing)
  end

  @doc """
  `POST /Sessions/Playing/Progress` — periodic progress.
  """
  def progress(conn, params) do
    record_session_state(conn, %{
      item_id: params["ItemId"] || params["itemId"] || params["item_id"],
      position_ticks: parse_int(params["PositionTicks"] || params["positionTicks"]),
      is_paused: parse_bool(params["IsPaused"] || params["isPaused"]) == true
    })

    report(conn, params, :progress)
  end

  @doc """
  `POST /Sessions/Playing/Stopped` — client stopped playback.
  """
  def stopped(conn, params) do
    record_session_state(conn, %{item_id: nil, position_ticks: nil, is_paused: false})
    report(conn, params, :stopped)
  end

  @doc """
  `POST /Users/:user_id/PlayedItems/:item_id` — mark item played.
  """
  def mark_played(conn, %{"user_id" => user_id, "item_id" => item_id}) do
    if authorized_user?(conn, user_id) do
      case UserData.upsert(conn.assigns.current_user.id, item_id, %{
             played: true,
             playback_position_ticks: 0,
             played_percentage: 100.0,
             last_played_date: now()
           }) do
        {:ok, ud} ->
          json(conn, Hivefin.Jellyfin.Dto.UserData.from_user_data(ud))

        {:error, _} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{"error" => "invalid"})
      end
    else
      conn
      |> put_status(:forbidden)
      |> json(%{"error" => "forbidden"})
    end
  end

  @doc """
  `POST /Users/:user_id/Items/:item_id/UserData` — set UserData fields.
  """
  def update_user_data(conn, %{"user_id" => user_id, "item_id" => item_id} = params) do
    if authorized_user?(conn, user_id) do
      attrs = user_data_attrs_from_body(params)

      case UserData.upsert(conn.assigns.current_user.id, item_id, attrs) do
        {:ok, ud} ->
          json(conn, Hivefin.Jellyfin.Dto.UserData.from_user_data(ud))

        {:error, _} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{"error" => "invalid"})
      end
    else
      conn
      |> put_status(:forbidden)
      |> json(%{"error" => "forbidden"})
    end
  end

  @doc """
  `POST /Sessions/:session_id/Playing` — tell a session to play items.
  """
  def play(conn, %{"session_id" => session_id} = params) do
    user = conn.assigns.current_user

    params
    |> play_data()
    |> then(&WsCommand.play(user.id, &1))
    |> deliver(conn, session_id)
  end

  @doc """
  `POST /Sessions/:session_id/Playing/:command` — pause/seek/stop a session.
  """
  def playstate(conn, %{"session_id" => session_id, "command" => command} = params) do
    params
    |> playstate_data()
    |> then(&WsCommand.playstate(command, &1))
    |> deliver(conn, session_id)
  end

  @doc """
  `POST /Sessions/:session_id/Command/:command` — a GeneralCommand.
  """
  def command(conn, %{"session_id" => session_id, "command" => command} = params) do
    user = conn.assigns.current_user
    arguments = Map.drop(params, ["session_id", "command"] ++ @credential_params)

    command
    |> WsCommand.general(user.id, arguments)
    |> deliver(conn, session_id)
  end

  @doc """
  `POST /Sessions/:session_id/Message` — display a message on a session.
  """
  def message(conn, %{"session_id" => session_id} = params) do
    user = conn.assigns.current_user
    arguments = Map.take(params, ["Header", "Text", "TimeoutMs"])

    "DisplayMessage"
    |> WsCommand.general(user.id, arguments)
    |> deliver(conn, session_id)
  end

  # Real clients send these as query-string params, so every value arrives as
  # a string (and possibly under a camelCase key, like the rest of this
  # file's params["ItemId"] || params["itemId"] handling). Built from an
  # explicit allowlist with coercion, not Map.drop(["session_id"]) over
  # everything else — Map.drop let through wrong-typed known keys (kotlinx
  # serialization discards the whole message on a type mismatch, same as a
  # missing required key) and any other query param the caller happened to
  # send, credentials included.
  defp play_data(params) do
    %{}
    |> maybe_put("PlayCommand", params["PlayCommand"] || params["playCommand"])
    |> maybe_put("ItemIds", item_ids(params["ItemIds"] || params["itemIds"]))
    |> maybe_put(
      "StartPositionTicks",
      parse_int(params["StartPositionTicks"] || params["startPositionTicks"])
    )
  end

  defp playstate_data(params) do
    maybe_put(
      %{},
      "SeekPositionTicks",
      parse_int(params["SeekPositionTicks"] || params["seekPositionTicks"])
    )
  end

  # `PlayRequest.itemIds` is `List<UUID>` client-side; a real client sends it
  # as a comma-separated query string, not a JSON array.
  defp item_ids(nil), do: nil
  defp item_ids(ids) when is_list(ids), do: Enum.map(ids, &to_string/1)
  defp item_ids(ids) when is_binary(ids), do: String.split(ids, ",", trim: true)
  defp item_ids(_), do: nil

  defp deliver({:error, :invalid_command}, conn, _session_id) do
    conn |> put_status(:bad_request) |> json(%{"error" => "invalid_command"})
  end

  defp deliver(message, conn, session_id) when is_map(message) do
    # session_id round-trips through Id.coerce/1 because the id clients are
    # ever given (GET /Sessions "Id", the Sessions socket push) is the
    # dashless wire form, but the session registry key is the raw dashed
    # access-token id — pushing the dashless form as-is always misses.
    #
    # own_session?/2 scopes delivery to the caller's own sessions (a real
    # client only ever advertises its own devices via GET /Sessions, but
    # nothing else enforced that here) — 404, not 403, so a wrong target
    # doesn't confirm another user's session exists.
    #
    # No live socket for session_id is today's only capability signal (a live
    # socket now reports SupportsMediaControl/SupportsRemoteControl: true,
    # see Dto.Session.from_access_token/2's :controllable option) — so gate
    # by attempting the push, not by a separate controllable? lookup that
    # would just re-derive the same fact from the registry.
    session_id = Id.coerce(session_id)

    if own_session?(session_id, conn.assigns.current_user.id) do
      case Sessions.push(session_id, message) do
        :ok -> send_resp(conn, :no_content, "")
        {:error, :no_session} -> no_session(conn)
      end
    else
      no_session(conn)
    end
  end

  defp own_session?(session_id, user_id) do
    session_id
    |> Sessions.attrs()
    |> Enum.any?(&(Map.get(&1, :user_id) == user_id))
  end

  defp no_session(conn), do: conn |> put_status(:not_found) |> json(%{"error" => "no_session"})

  # Records now-playing state on the caller's own session so other clients can
  # see it. put_state/2 (not update/2) because this runs in a request process.
  defp record_session_state(conn, attrs) do
    case conn.assigns[:current_access_token] do
      %{id: session_id} -> Sessions.put_state(session_id, attrs)
      _ -> :ok
    end

    :ok
  end

  defp report(conn, params, _kind) do
    user = conn.assigns.current_user
    item_id = params["ItemId"] || params["itemId"] || params["item_id"]
    position = parse_int(params["PositionTicks"] || params["positionTicks"])
    explicit_played = parse_bool(params["Played"] || params["played"])
    explicit_pct = parse_float(params["PlayedPercentage"] || params["playedPercentage"])

    if is_binary(item_id) and item_id != "" do
      attrs =
        %{last_played_date: now()}
        |> maybe_put(:playback_position_ticks, position)
        |> maybe_put(:played_percentage, explicit_pct)
        |> maybe_put(:played, explicit_played)
        |> apply_completion(user.id, item_id, position, explicit_played, explicit_pct)

      case UserData.upsert(user.id, item_id, attrs) do
        {:ok, _} ->
          conn
          |> put_status(:no_content)
          |> send_resp(:no_content, "")

        {:error, _} ->
          # Unknown item / FK — still acknowledge so clients keep working.
          conn
          |> put_status(:no_content)
          |> send_resp(:no_content, "")
      end
    else
      conn
      |> put_status(:no_content)
      |> send_resp(:no_content, "")
    end
  end

  # When the client does not set Played, complete if position is near the end.
  defp apply_completion(attrs, user_id, item_id, position, explicit_played, explicit_pct) do
    runtime = LibraryContext.item_runtime_ticks(item_id)

    attrs =
      if is_nil(explicit_pct) and is_integer(position) and is_integer(runtime) and runtime > 0 do
        pct = position / runtime * 100.0
        Map.put(attrs, :played_percentage, pct |> min(100.0) |> Float.round(1))
      else
        attrs
      end

    cond do
      # Client explicitly set Played — respect it (except clear resume on true)
      explicit_played == true ->
        attrs
        |> Map.put(:playback_position_ticks, 0)
        |> Map.put(:played_percentage, 100.0)
        |> maybe_increment_play_count(user_id, item_id)

      explicit_played == false ->
        attrs

      is_integer(position) and is_integer(runtime) and runtime > 0 and
          completed_position?(position, runtime) ->
        attrs
        |> Map.put(:played, true)
        |> Map.put(:playback_position_ticks, 0)
        |> Map.put(:played_percentage, 100.0)
        |> maybe_increment_play_count(user_id, item_id)

      true ->
        attrs
    end
  end

  defp completed_position?(position, runtime) when runtime > 0 do
    position >= trunc(runtime * @completion_ratio) or position >= runtime
  end

  defp completed_position?(_, _), do: false

  defp maybe_increment_play_count(attrs, user_id, item_id) do
    # Only bump when transitioning into played; avoid double-count on progress spam
    # once already marked played (unless client is re-finishing with position at end).
    case UserData.get(user_id, item_id) do
      %{played: true, play_count: n} when is_integer(n) and n > 0 ->
        attrs

      %{play_count: n} when is_integer(n) ->
        Map.put(attrs, :play_count, n + 1)

      _ ->
        Map.put(attrs, :play_count, 1)
    end
  end

  defp authorized_user?(conn, user_id) do
    Hivefin.Jellyfin.Id.coerce(conn.assigns.current_user.id) ==
      Hivefin.Jellyfin.Id.coerce(user_id)
  end

  defp user_data_attrs_from_body(params) do
    %{
      playback_position_ticks:
        parse_int(params["PlaybackPositionTicks"] || params["playbackPositionTicks"]),
      played_percentage: parse_float(params["PlayedPercentage"] || params["playedPercentage"]),
      played: parse_bool(params["Played"] || params["played"]),
      play_count: parse_int(params["PlayCount"] || params["playCount"]),
      is_favorite: parse_bool(params["IsFavorite"] || params["isFavorite"]),
      last_played_date: now()
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

  defp parse_int(nil), do: nil
  defp parse_int(n) when is_integer(n), do: n

  defp parse_int(n) when is_binary(n) do
    case Integer.parse(n) do
      {i, _} -> i
      :error -> nil
    end
  end

  defp parse_int(n) when is_float(n), do: trunc(n)
  defp parse_int(_), do: nil

  defp parse_float(nil), do: nil
  defp parse_float(n) when is_float(n), do: n
  defp parse_float(n) when is_integer(n), do: n * 1.0

  defp parse_float(n) when is_binary(n) do
    case Float.parse(n) do
      {f, _} -> f
      :error -> nil
    end
  end

  defp parse_float(_), do: nil

  defp parse_bool(nil), do: nil
  defp parse_bool(true), do: true
  defp parse_bool(false), do: false
  defp parse_bool("true"), do: true
  defp parse_bool("True"), do: true
  defp parse_bool("false"), do: false
  defp parse_bool("False"), do: false
  defp parse_bool(_), do: nil

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(v), do: v
end
