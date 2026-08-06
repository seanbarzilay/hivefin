defmodule Hivefin.Metadata.Worker do
  @moduledoc """
  Best-effort metadata refresh for library items.

  Failures are logged and never raised to the scan pipeline.
  """

  require Logger

  alias Hivefin.Library.{Item, LibraryContext}
  alias Hivefin.Metadata.{ImageCache, Matcher, TMDB}
  alias Hivefin.Repo

  @doc """
  Synchronously refreshes metadata for a movie item.

  Always returns `:ok` (errors are logged).
  """
  @spec refresh_item(Ecto.UUID.t()) :: :ok
  def refresh_item(item_id) when is_binary(item_id) do
    case LibraryContext.get_item(item_id) do
      %Item{type: :movie} = item ->
        do_refresh_movie(item)

      %Item{} ->
        Logger.debug("metadata refresh skipped for non-movie item #{item_id}")
        :ok

      nil ->
        Logger.debug("metadata refresh skipped: item #{item_id} not found")
        :ok
    end
  rescue
    e ->
      Logger.warning("metadata refresh crashed for #{item_id}: #{Exception.message(e)}")
      :ok
  end

  def refresh_item(_), do: :ok

  @doc """
  Enqueues an async refresh under the metadata task supervisor.

  Best-effort: returns `:ok` even if the task cannot be started.
  Disabled when `config :hivefin, :metadata_enqueue, false` (tests).
  """
  @spec enqueue_refresh(Ecto.UUID.t()) :: :ok
  def enqueue_refresh(item_id) when is_binary(item_id) do
    if Application.get_env(:hivefin, :metadata_enqueue, true) do
      _ =
        Task.Supervisor.start_child(Hivefin.Metadata.TaskSupervisor, fn ->
          allow_repo_sandbox()
          refresh_item(item_id)
        end)
    end

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  def enqueue_refresh(_), do: :ok

  defp do_refresh_movie(item) do
    case Matcher.match_movie(item) do
      {:ok, match} ->
        _ = apply_match(item, match)
        _ = maybe_store_images(item.id, match)
        :ok

      {:error, reason} ->
        Logger.info("metadata match failed for item #{item.id}: #{inspect(reason)}")
        :ok
    end
  end

  defp apply_match(%Item{} = item, match) do
    provider_ids =
      Map.merge(item.provider_ids || %{}, match[:provider_ids] || %{})

    attrs =
      %{
        overview: match[:overview] || item.overview,
        provider_ids: provider_ids
      }
      |> maybe_put(:production_year, match[:production_year] || item.production_year)
      |> maybe_put(:premiere_date, match[:premiere_date] || item.premiere_date)

    item
    |> Item.changeset(attrs)
    |> Repo.update()
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_store_images(item_id, match) do
    provider = Application.get_env(:hivefin, :metadata_provider, TMDB)

    if poster = provider.image_url(match[:poster_path], :poster) do
      case ImageCache.store(item_id, :primary, poster) do
        {:ok, _} -> :ok
        {:error, reason} -> Logger.warning("primary image store failed: #{inspect(reason)}")
      end
    end

    if backdrop = provider.image_url(match[:backdrop_path], :backdrop) do
      case ImageCache.store(item_id, :backdrop, backdrop) do
        {:ok, _} -> :ok
        {:error, reason} -> Logger.warning("backdrop image store failed: #{inspect(reason)}")
      end
    end

    :ok
  end

  defp allow_repo_sandbox do
    case Application.get_env(:hivefin, :metadata_repo_owner) ||
           Application.get_env(:hivefin, :scanner_repo_owner) do
      owner when is_pid(owner) ->
        Ecto.Adapters.SQL.Sandbox.allow(Repo, owner, self())

      _ ->
        :ok
    end
  end
end
