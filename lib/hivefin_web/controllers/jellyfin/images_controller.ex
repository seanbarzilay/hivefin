defmodule HivefinWeb.Jellyfin.ImagesController do
  use HivefinWeb, :controller

  alias Hivefin.Jellyfin.Id
  alias Hivefin.Library.Person
  alias Hivefin.Metadata.{ImageCache, TMDB}
  alias Hivefin.Repo

  @doc """
  Serves a cached item or person image (`Primary` / `Backdrop`) when present.

  Headshots are fetched lazily: on a cache miss for a person id with a
  non-nil `profile_path`, this fetches the image from TMDb on the spot,
  caches it, and serves it — the only place a person headshot is ever
  downloaded (metadata refresh never fetches them, see `Metadata.Worker`).

  Returns 404 when there's nothing cached and nothing to lazily fetch
  (missing item image, or a person with no `profile_path`), and also on a
  failed fetch — a broken `profile_path` or a TMDb error must never 500 this
  request.
  """
  def show(conn, %{"item_id" => item_id, "image_type" => image_type}) do
    item_id = Id.coerce(item_id)

    case ImageCache.path_for(item_id, image_type) do
      {:ok, path} ->
        serve(conn, path)

      :error ->
        case fetch_person_headshot(item_id, image_type) do
          {:ok, path} -> serve(conn, path)
          :error -> not_found(conn)
        end
    end
  end

  def show(conn, _params) do
    not_found(conn)
  end

  # Two concurrent requests for the same uncached face can both download;
  # the loser hits images_person_id_type_unique_index and store_person/2
  # returns {:error, changeset} (not a raise) — self-healing, since the
  # winner's row already makes the next request a cache hit.
  defp fetch_person_headshot(person_id, image_type) do
    with true <- String.downcase(to_string(image_type)) == "primary",
         %Person{profile_path: profile_path} when is_binary(profile_path) <-
           Repo.get(Person, person_id),
         url when is_binary(url) <- TMDB.image_url(profile_path, :profile),
         {:ok, path} <- ImageCache.store_person(person_id, url) do
      {:ok, path}
    else
      _ -> :error
    end
  end

  defp serve(conn, path) do
    conn
    |> put_resp_content_type(content_type(path))
    |> put_resp_header("cache-control", "public, max-age=86400")
    |> send_file(200, path)
  end

  defp not_found(conn) do
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
