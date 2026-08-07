defmodule HivefinWeb.Jellyfin.LiveTvController do
  @moduledoc """
  Live TV is not implemented; recordings must still return an empty
  query-result shape, not the SPA HTML fallback (the dashboard reads `.Items`).
  """
  use HivefinWeb, :controller

  @doc """
  `GET /LiveTv/Recordings` — empty BaseItemDtoQueryResult.
  """
  def recordings(conn, _params) do
    json(conn, %{"Items" => [], "TotalRecordCount" => 0, "StartIndex" => 0})
  end
end
