defmodule HivefinWeb.Jellyfin.SessionsController do
  @moduledoc """
  Jellyfin sessions listing, capability stubs, and progress reporting.
  """

  use HivefinWeb, :controller

  alias Hivefin.Accounts
  alias Hivefin.Jellyfin.Dto.Session, as: SessionDto
  alias Hivefin.Library.UserData

  @doc """
  `GET /Sessions` — active device sessions for the current user (access tokens).
  """
  def index(conn, params) do
    device_id = blank_to_nil(params["deviceId"] || params["DeviceId"])
    user = conn.assigns.current_user

    sessions =
      Accounts.list_access_tokens(user_id: user.id, device_id: device_id)
      |> Enum.map(&SessionDto.from_access_token/1)

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
    report(conn, params, :playing)
  end

  @doc """
  `POST /Sessions/Playing/Progress` — periodic progress.
  """
  def progress(conn, params) do
    report(conn, params, :progress)
  end

  @doc """
  `POST /Sessions/Playing/Stopped` — client stopped playback.
  """
  def stopped(conn, params) do
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

  defp report(conn, params, _kind) do
    user = conn.assigns.current_user
    item_id = params["ItemId"] || params["itemId"] || params["item_id"]
    position = parse_int(params["PositionTicks"] || params["positionTicks"])

    if is_binary(item_id) and item_id != "" do
      attrs =
        %{last_played_date: now()}
        |> maybe_put(:playback_position_ticks, position)
        |> maybe_put(
          :played_percentage,
          parse_float(params["PlayedPercentage"] || params["playedPercentage"])
        )
        |> maybe_put(:played, parse_bool(params["Played"] || params["played"]))

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
