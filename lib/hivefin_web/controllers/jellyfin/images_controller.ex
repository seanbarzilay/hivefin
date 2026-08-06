defmodule HivefinWeb.Jellyfin.ImagesController do
  use HivefinWeb, :controller

  @doc """
  Image route stub. Returns 404 until metadata image cache is implemented.
  """
  def show(conn, _params) do
    conn
    |> put_status(:not_found)
    |> json(%{"error" => "image_not_found"})
  end
end
