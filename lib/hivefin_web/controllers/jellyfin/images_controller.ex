defmodule HivefinWeb.Jellyfin.ImagesController do
  use HivefinWeb, :controller

  alias Hivefin.Metadata.ImageCache

  @doc """
  Serves a cached item image (`Primary` / `Backdrop`) when present.

  Returns 404 when no cache entry or file is missing.
  """
  def show(conn, %{"item_id" => item_id, "image_type" => image_type}) do
    case ImageCache.path_for(item_id, image_type) do
      {:ok, path} ->
        conn
        |> put_resp_content_type(content_type(path))
        |> put_resp_header("cache-control", "public, max-age=86400")
        |> send_file(200, path)

      :error ->
        conn
        |> put_status(:not_found)
        |> json(%{"error" => "image_not_found"})
    end
  end

  def show(conn, _params) do
    conn
    |> put_status(:not_found)
    |> json(%{"error" => "image_not_found"})
  end

  defp content_type(path) do
    case path |> Path.extname() |> String.downcase() do
      ".png" -> "image/png"
      ".webp" -> "image/webp"
      ".gif" -> "image/gif"
      _ -> "image/jpeg"
    end
  end
end
