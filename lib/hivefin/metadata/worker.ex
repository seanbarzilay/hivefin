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

  Always returns `:ok` (errors are logged). Catches exceptions and GenServer
  call exits (e.g. rate-limiter timeout) so async Tasks stay quiet.
  """
  @spec refresh_item(Ecto.UUID.t()) :: :ok
  def refresh_item(item_id) when is_binary(item_id) do
    allow_repo_sandbox()

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
      Logger.warning(
        "metadata refresh crashed for #{item_id}: #{TMDB.redact_secrets(Exception.message(e))}"
      )

      :ok
  catch
    :exit, reason ->
      Logger.warning("metadata refresh exited for #{item_id}: #{TMDB.redact_secrets(reason)}")

      :ok
  end

  def refresh_item(_), do: :ok

  @doc """
  Enqueues an async refresh on the bounded metadata queue.

  Best-effort: returns `:ok` even if the queue is unavailable.
  Disabled when `config :hivefin, :metadata_enqueue, false` (tests).
  """
  @spec enqueue_refresh(Ecto.UUID.t()) :: :ok
  def enqueue_refresh(item_id) when is_binary(item_id) do
    if Application.get_env(:hivefin, :metadata_enqueue, true) do
      Hivefin.Metadata.Queue.enqueue(item_id)
    end

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  def enqueue_refresh(_), do: :ok

  @doc """
  Enqueues metadata refresh for movies that lack a TMDB id and/or a primary
  poster. Returns the number of item ids queued.

  Safe to call repeatedly; the queue dedupes ids already pending/running.
  """
  @spec enqueue_missing_movies(keyword()) :: non_neg_integer()
  def enqueue_missing_movies(opts \\ []) do
    limit = Keyword.get(opts, :limit)

    ids = list_missing_movie_ids(limit)
    Enum.each(ids, &enqueue_refresh/1)
    length(ids)
  end

  @doc """
  Movie ids missing provider metadata, a primary image row, and/or credits.
  """
  @spec list_missing_movie_ids(pos_integer() | nil) :: [Ecto.UUID.t()]
  def list_missing_movie_ids(limit \\ nil) do
    import Ecto.Query

    alias Hivefin.Library.{Image, ItemPerson}

    q =
      from(i in Item,
        as: :item,
        left_join: img in Image,
        on: img.item_id == i.id and img.type == :primary,
        where: i.type == :movie,
        # A movie qualifies as "missing metadata" if it has no poster, no
        # provider match, OR no credits. That third branch is the backfill:
        # the library was matched to TMDb before cast & crew shipped, so
        # every movie already has a poster and provider_ids and would
        # otherwise never re-qualify. NOT EXISTS (not another left_join)
        # because item_people is one-to-many and a join would multiply rows
        # before the select. Movies TMDb genuinely has no credits for will
        # re-qualify on every call — acceptable, since this only runs
        # admin-triggered and is bounded by the queue and rate limiter.
        where:
          is_nil(img.id) or is_nil(i.provider_ids) or
            fragment("coalesce(?::text, '{}') IN ('{}', 'null')", i.provider_ids) or
            not exists(
              from(ip in ItemPerson, where: ip.item_id == parent_as(:item).id, select: 1)
            ),
        select: i.id,
        order_by: [asc: i.name]
      )

    q =
      case limit do
        n when is_integer(n) and n > 0 -> limit(q, ^n)
        _ -> q
      end

    Repo.all(q)
  end

  defp do_refresh_movie(item) do
    case Matcher.match_movie(item) do
      {:ok, match} ->
        _ = apply_match(item, match)
        _ = maybe_store_images(item.id, match)
        :ok

      {:error, reason} ->
        Logger.info("metadata match failed for item #{item.id}: #{TMDB.redact_secrets(reason)}")

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

    result =
      item
      |> Item.changeset(attrs)
      |> Repo.update()

    # People are stored separately from the item's own columns; a credits
    # failure must not roll back the item metadata we just wrote.
    # PeopleContext.replace_for_item/2 treats [] as a no-op, so a missing or
    # empty :people key here can't wipe credits an item already has.
    people = match[:people] || []

    case Hivefin.Library.PeopleContext.replace_for_item(item.id, people) do
      {:ok, _count} when people != [] -> fetch_headshots(item.id, people)
      _ -> :ok
    end

    result
  end

  # Best-effort headshot fetch, one person at a time: a 404, a broken
  # profile_path, or a rate-limit rejection on one person must not skip the
  # rest or roll back the credits replace_for_item/2 just committed. Mirrors
  # maybe_store_images/2's per-artifact isolation below. People with no
  # profile_path (most crew, per TMDb) never reach ImageCache at all —
  # headshot_targets/2 already filters those out.
  defp fetch_headshots(item_id, people) do
    item_id
    |> Hivefin.Library.PeopleContext.headshot_targets(people)
    |> Enum.each(fn {person_id, profile_path} ->
      case TMDB.image_url(profile_path, :profile) do
        nil ->
          :ok

        url ->
          case ImageCache.store_person(person_id, url) do
            {:ok, _} ->
              :ok

            {:error, reason} ->
              Logger.warning("headshot store failed: #{TMDB.redact_secrets(reason)}")
          end
      end
    end)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_store_images(item_id, match) do
    provider = Application.get_env(:hivefin, :metadata_provider, TMDB)

    if poster = provider.image_url(match[:poster_path], :poster) do
      case ImageCache.store(item_id, :primary, poster) do
        {:ok, _} ->
          :ok

        {:error, reason} ->
          Logger.warning("primary image store failed: #{TMDB.redact_secrets(reason)}")
      end
    end

    if backdrop = provider.image_url(match[:backdrop_path], :backdrop) do
      case ImageCache.store(item_id, :backdrop, backdrop) do
        {:ok, _} ->
          :ok

        {:error, reason} ->
          Logger.warning("backdrop image store failed: #{TMDB.redact_secrets(reason)}")
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
