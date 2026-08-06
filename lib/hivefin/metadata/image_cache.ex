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

  Returns `{:ok, absolute_path}` or `{:error, reason}`.
  """
  @spec store(Ecto.UUID.t(), :primary | :backdrop, String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def store(item_id, type, url)
      when is_binary(item_id) and type in [:primary, :backdrop] and is_binary(url) do
    with :ok <- ensure_cache_dir(),
         {:ok, body, content_type} <- download(url),
         ext <- extension_for(url, content_type),
         path <- cache_path(item_id, type, ext),
         :ok <- write_file(path, body),
         {:ok, _image} <- upsert_image(item_id, type, path) do
      {:ok, path}
    end
  end

  def store(_, _, _), do: {:error, :invalid_args}

  @doc """
  Returns the absolute path for a cached image, or `:error`.
  """
  @spec path_for(Ecto.UUID.t(), :primary | :backdrop | String.t()) ::
          {:ok, String.t()} | :error
  def path_for(item_id, type) when is_binary(item_id) do
    type = normalize_type(type)

    case type do
      nil ->
        :error

      type ->
        case get_image(item_id, type) do
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

  Uses preloaded `images` when present; queries by id only when given a bare item id.
  Unloaded associations yield `%{}` (callers that need tags should preload).
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
        if File.regular?(path), do: Map.put(acc, "Primary", id), else: acc

      %Image{type: :backdrop, id: id, local_path: path}, acc when is_binary(path) ->
        if File.regular?(path), do: Map.put(acc, "Backdrop", id), else: acc

      _, acc ->
        acc
    end)
  end

  defp get_image(item_id, type) do
    Repo.get_by(Image, item_id: item_id, type: type)
  end

  defp upsert_image(item_id, type, path) do
    attrs = %{
      item_id: item_id,
      type: type,
      local_path: path,
      provider: "tmdb"
    }

    case Repo.get_by(Image, item_id: item_id, type: type) do
      nil ->
        %Image{}
        |> Image.changeset(attrs)
        |> Repo.insert()

      existing ->
        # Remove previous file if path changed
        if is_binary(existing.local_path) and existing.local_path != path do
          _ = File.rm(existing.local_path)
        end

        existing
        |> Image.changeset(attrs)
        |> Repo.update()
    end
  end

  defp download(url) do
    opts = [url: url, decode_body: false] ++ req_options()

    case Req.get(opts) do
      {:ok, %Req.Response{status: 200, body: body, headers: headers}}
      when is_binary(body) and byte_size(body) > 0 ->
        ct = header_value(headers, "content-type")
        {:ok, body, ct}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        Logger.warning("image download failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp req_options do
    # Image CDN downloads still honor test plugs when configured.
    Application.get_env(:hivefin, :metadata_req_options, [])
  end

  defp header_value(headers, name) do
    name = String.downcase(name)

    Enum.find_value(headers, fn
      {k, v} ->
        if String.downcase(to_string(k)) == name do
          v |> List.wrap() |> List.first()
        end
    end)
  end

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
