defmodule Hivefin.Jellyfin.Dto.UserData do
  @moduledoc """
  Maps domain `Hivefin.Library.UserData` to Jellyfin UserItemDataDto-shaped maps.
  """

  alias Hivefin.Library.UserData, as: DomainUserData

  @doc """
  Builds a UserItemDataDto map from a domain UserData row or nil.
  """
  def from_user_data(nil), do: default()

  def from_user_data(%DomainUserData{} = ud) do
    %{
      "PlaybackPositionTicks" => ud.playback_position_ticks || 0,
      "PlayedPercentage" => ud.played_percentage || 0.0,
      "Played" => ud.played || false,
      "PlayCount" => ud.play_count || 0,
      "IsFavorite" => ud.is_favorite || false,
      "LastPlayedDate" => last_played_date(ud.last_played_date)
    }
    |> drop_nils()
  end

  def from_user_data(%{} = map) do
    Map.merge(default(), stringify_keys(map))
  end

  def default do
    %{
      "PlaybackPositionTicks" => 0,
      "PlayCount" => 0,
      "IsFavorite" => false,
      "Played" => false,
      "PlayedPercentage" => 0
    }
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
