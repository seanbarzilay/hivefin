defmodule Hivefin.Metadata.ImageCache do
  @moduledoc """
  Downloads provider artwork into `HIVEFIN_IMAGE_CACHE_DIR` and tracks rows in `images`.
  """

  require Logger

  import Ecto.Query

  alias Hivefin.Library.Image
  alias Hivefin.Repo

  @doc """
  Downloads `url` into the cache for `item_id` / `type` (`:primary` | `:backdrop`).

  Skips the download and returns the existing path when an `Image` row
  already exists for `(item_id, type)` and its file is still on disk — the
  common case on every metadata refresh after the first. This is the only
  caller of `ImageCache.store/3` in the codebase (both `Worker.maybe_store_images/2`
  call sites), so there's no other consumer relying on the old
  always-redownload behavior to pick up a changed provider image.

  Returns `{:ok, absolute_path}` or `{:error, reason}`.
  """
  @spec store(Ecto.UUID.t(), :primary | :backdrop, String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def store(item_id, type, url)
      when is_binary(item_id) and type in [:primary, :backdrop] and is_binary(url) do
    case cached_path(item_id, type) do
      {:ok, path} ->
        {:ok, path}

      :miss ->
        with :ok <- ensure_cache_dir(),
             {:ok, body, content_type} <- download(url),
             ext <- extension_for(url, content_type),
             path <- cache_path(item_id, type, ext),
             :ok <- write_file(path, body),
             {:ok, _image} <- upsert_image(item_id, type, path) do
          {:ok, path}
        end
    end
  end

  def store(_, _, _), do: {:error, :invalid_args}

  @doc """
  Downloads and caches a person's headshot into the cache dir. Always
  `:primary` — persons have no backdrop.

  Skips the download the same way `store/3` does: an existing `Image` row
  for `person_id` with a file still on disk is reused rather than
  re-fetched. `ImagesController` is the only caller — a person's headshot is
  fetched lazily, on the first client request for it, never at metadata
  refresh time.

  A failed fetch (TMDb 404, timeout, `:rate_limited`, …) persists an `Image`
  row with `local_path: nil` as a "don't retry" marker: this endpoint is
  unauthenticated, so without it a permanently-missing photo would be
  re-attempted, and re-burn a shared `RateLimiter` token, on every view by
  every anonymous caller, forever. `PeopleContext.update_profile_path/2`
  deletes this marker (and any real cached file) the moment a legitimate
  metadata refresh actually changes `profile_path` — that's what lets a
  since-fixed or since-changed photo be fetched again.

  Returns `{:ok, absolute_path}` or `{:error, reason}`. `{:error, :no_photo}`
  specifically means "already tried, marked as failed, not retrying."
  """
  @spec store_person(Ecto.UUID.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def store_person(person_id, url) when is_binary(person_id) and is_binary(url) do
    case cached_person_path(person_id) do
      {:ok, path} ->
        {:ok, path}

      :failed ->
        {:error, :no_photo}

      :miss ->
        with :ok <- ensure_cache_dir(),
             {:ok, body, content_type} <- download(url),
             ext <- extension_for(url, content_type),
             path <- cache_path(person_id, :primary, ext),
             :ok <- write_file(path, body),
             {:ok, _image} <- upsert_person_image(person_id, path) do
          {:ok, path}
        else
          {:error, reason} ->
            _ = mark_person_headshot_failed(person_id)
            {:error, reason}
        end
    end
  end

  def store_person(_, _), do: {:error, :invalid_args}

  defp cached_path(item_id, type) do
    path_from_image(get_image(item_id, type))
  end

  defp cached_person_path(person_id) do
    case get_person_image(person_id, :primary) do
      nil -> :miss
      %Image{local_path: nil} -> :failed
      image -> path_from_image(image)
    end
  end

  defp mark_person_headshot_failed(person_id) do
    _ = upsert_person_image(person_id, nil)
    :ok
  end

  defp path_from_image(%Image{local_path: path}) when is_binary(path) do
    if File.regular?(path), do: {:ok, path}, else: :miss
  end

  defp path_from_image(_), do: :miss

  @doc """
  Returns the absolute path for a cached image, or `:error`.

  `id` may be an item id or a person id — `ImagesController` serves person
  headshots from `/Items/{personId}/Images/Primary`, matching upstream
  Jellyfin where persons are items. Items are resolved before people, so an
  id that (impossibly, today) matched both would prefer the item.
  """
  @spec path_for(Ecto.UUID.t(), :primary | :backdrop | String.t()) ::
          {:ok, String.t()} | :error
  def path_for(id, type) when is_binary(id) do
    type = normalize_type(type)

    case type do
      nil ->
        :error

      type ->
        image = get_image(id, type) || get_person_image(id, type)

        case image do
          %Image{local_path: path} when is_binary(path) ->
            if File.regular?(path), do: {:ok, path}, else: :error

          _ ->
            :error
        end
    end
  end

  @doc """
  Builds Jellyfin-style ImageTags map for an item (`%{"Primary" => tag, ...}`).
  Tag is the image row id (stable cache buster).

  Uses preloaded `images` when present; queries by id only when given a bare
  item id. Unloaded associations yield `%{}` (callers that need tags should
  preload).

  Person headshot tags do NOT go through this function — BaseItem derives
  `PrimaryImageTag` for a person straight from `Person.profile_path` (a hash
  of it), never from a per-person `images` query. See
  `Hivefin.Jellyfin.Dto.BaseItem.person_entry/1`.
  """
  def image_tags_for(%{images: images}) when is_list(images) do
    tags_from_images(images)
  end

  def image_tags_for(%{images: %Ecto.Association.NotLoaded{}}), do: %{}

  def image_tags_for(item_id) when is_binary(item_id) do
    images =
      from(i in Image, where: i.item_id == ^item_id)
      |> Repo.all()

    tags_from_images(images)
  end

  def image_tags_for(_), do: %{}

  @doc """
  Cache root directory from config.
  """
  def cache_dir do
    Application.get_env(
      :hivefin,
      :image_cache_dir,
      Path.join(System.tmp_dir!(), "hivefin-image-cache")
    )
  end

  defp tags_from_images(images) do
    Enum.reduce(images, %{}, fn
      %Image{type: :primary, id: id, local_path: path}, acc when is_binary(path) ->
        if File.regular?(path),
          do: Map.put(acc, "Primary", Hivefin.Jellyfin.Id.format(id)),
          else: acc

      %Image{type: :backdrop, id: id, local_path: path}, acc when is_binary(path) ->
        if File.regular?(path),
          do: Map.put(acc, "Backdrop", Hivefin.Jellyfin.Id.format(id)),
          else: acc

      _, acc ->
        acc
    end)
  end

  defp get_image(item_id, type) do
    Repo.get_by(Image, item_id: item_id, type: type)
  end

  defp get_person_image(person_id, type) do
    Repo.get_by(Image, person_id: person_id, type: type)
  end

  defp upsert_image(item_id, type, path) do
    upsert(get_image(item_id, type), %{
      item_id: item_id,
      type: type,
      local_path: path,
      provider: "tmdb"
    })
  end

  defp upsert_person_image(person_id, path) do
    upsert(get_person_image(person_id, :primary), %{
      person_id: person_id,
      type: :primary,
      local_path: path,
      provider: "tmdb"
    })
  end

  defp upsert(existing, attrs)

  defp upsert(nil, attrs) do
    %Image{}
    |> Image.changeset(attrs)
    |> Repo.insert()
  end

  defp upsert(existing, attrs) do
    # Remove previous file if path changed
    if is_binary(existing.local_path) and existing.local_path != attrs.local_path do
      _ = File.rm(existing.local_path)
    end

    existing
    |> Image.changeset(attrs)
    |> Repo.update()
  end

  # Shared by store/3 (eager poster/backdrop) and store_person/2 (lazy
  # on-demand headshot fetch from ImagesController). The rate limiter throttle
  # matters most for the latter: opening one big cast page can trigger dozens
  # of concurrent headshot fetches at once.
  defp download(url) do
    case Hivefin.Metadata.RateLimiter.checkout() do
      :ok -> do_download(url)
      :error -> {:error, :rate_limited}
    end
  end

  defp do_download(url) do
    case Hivefin.Http.get_body(url,
           decode_json: false,
           req_options: req_options()
         ) do
      {:ok, %{body: body, headers: headers}} when is_binary(body) and byte_size(body) > 0 ->
        ct = header_value(headers, "content-type")
        {:ok, body, ct}

      {:error, reason} = err ->
        Logger.warning("image download failed: #{inspect(reason)}")
        err
    end
  end

  defp req_options do
    # Image CDN downloads still honor test plugs when configured.
    Application.get_env(:hivefin, :metadata_req_options, [])
  end

  defp header_value(headers, name) when is_list(headers) do
    name = String.downcase(name)

    Enum.find_value(headers, fn
      {k, v} ->
        if String.downcase(to_string(k)) == name do
          v |> List.wrap() |> List.first()
        end
    end)
  end

  defp header_value(_, _), do: nil

  defp extension_for(url, content_type) do
    cond do
      is_binary(content_type) and String.contains?(content_type, "png") ->
        "png"

      is_binary(content_type) and String.contains?(content_type, "webp") ->
        "webp"

      is_binary(content_type) and String.contains?(content_type, "jpeg") ->
        "jpg"

      is_binary(content_type) and String.contains?(content_type, "jpg") ->
        "jpg"

      true ->
        case url |> URI.parse() |> Map.get(:path) |> to_string() |> Path.extname() do
          "." <> ext when ext != "" -> String.downcase(ext)
          _ -> "jpg"
        end
    end
  end

  defp cache_path(item_id, type, ext) do
    Path.join([cache_dir(), item_id, "#{type}.#{ext}"])
  end

  defp write_file(path, body) do
    dir = Path.dirname(path)

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(path, body) do
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_cache_dir do
    case File.mkdir_p(cache_dir()) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_type(type) when type in [:primary, :backdrop], do: type
  defp normalize_type("Primary"), do: :primary
  defp normalize_type("primary"), do: :primary
  defp normalize_type("Backdrop"), do: :backdrop
  defp normalize_type("backdrop"), do: :backdrop
  defp normalize_type("PRIMARY"), do: :primary
  defp normalize_type("BACKDROP"), do: :backdrop
  defp normalize_type(_), do: nil
end
