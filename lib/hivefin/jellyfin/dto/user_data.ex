defmodule Hivefin.Jellyfin.Dto.UserData do
  @moduledoc """
  Maps domain `Hivefin.Library.UserData` to Jellyfin UserItemDataDto-shaped maps.
  """

  alias Hivefin.Jellyfin.Id
  alias Hivefin.Library.UserData, as: DomainUserData

  @doc """
  Builds a UserItemDataDto map from a domain UserData row or nil.

  `item_id` is required by Android TV (UserItemDataDto.Key / ItemId).
  """
  def from_user_data(data, item_id \\ nil)

  def from_user_data(nil, item_id), do: default(item_id)

  def from_user_data(%DomainUserData{} = ud, item_id) do
    item_id = item_id || Map.get(ud, :item_id)

    %{
      "PlaybackPositionTicks" => ud.playback_position_ticks || 0,
      "PlayedPercentage" => ud.played_percentage || 0.0,
      "Played" => ud.played || false,
      "PlayCount" => ud.play_count || 0,
      "IsFavorite" => ud.is_favorite || false,
      "LastPlayedDate" => last_played_date(ud.last_played_date)
    }
    |> put_item_ids(item_id)
    |> drop_nils()
  end

  def from_user_data(%{} = map, item_id) do
    Map.merge(default(item_id), stringify_keys(map))
    |> put_item_ids(item_id)
  end

  def default(item_id \\ nil) do
    %{
      "PlaybackPositionTicks" => 0,
      "PlayCount" => 0,
      "IsFavorite" => false,
      "Played" => false,
      "PlayedPercentage" => 0
    }
    |> put_item_ids(item_id)
  end

  defp put_item_ids(map, nil), do: map

  defp put_item_ids(map, item_id) do
    id = Id.format(item_id)

    map
    |> Map.put_new("Key", id)
    |> Map.put_new("ItemId", id)
  end

  defp last_played_date(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp last_played_date(_), do: nil

  defp stringify_keys(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {k |> Atom.to_string() |> Macro.camelize(), v}
      {k, v} when is_binary(k) -> {k, v}
    end)
  end

  defp drop_nils(map) do
    map
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end
end
