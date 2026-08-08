defmodule HivefinWeb.Jellyfin.ImagesController do
  use HivefinWeb, :controller

  alias Hivefin.Jellyfin.Id
  alias Hivefin.Library.Person
  alias Hivefin.Metadata.{ImageCache, TMDB}
  alias Hivefin.Repo

  # Global cap on in-flight lazy headshot fetches, server-wide. The
  # RateLimiter sustains 4/sec; at that rate a full cap drains in ~2.5s
  # worst case instead of growing toward RateLimiter.checkout/1's 120s call
  # timeout. 10 comfortably exceeds a single browser's 6-sockets-per-origin
  # ceiling (HTTP/1.1), so one legitimate user opening one cast page is very
  # unlikely to ever get capped — only genuine bursts (many concurrent
  # pageviews, or abuse of this unauthenticated route) are.
  @max_concurrent_headshot_fetches 10
  @headshot_gate_key {__MODULE__, :headshot_fetch_gate}

  @doc """
  Serves a cached item or person image (`Primary` / `Backdrop`) when present.

  Headshots are fetched lazily: on a cache miss for a person id with a
  non-nil `profile_path`, this fetches the image from TMDb on the spot,
  caches it, and serves it — the only place a person headshot is ever
  downloaded (metadata refresh never fetches them, see `Metadata.Worker`).

  Returns 404 when there's nothing cached and nothing to lazily fetch
  (missing item image, or a person with no `profile_path`), and also on a
  failed fetch — a broken `profile_path` or a TMDb error must never 500 this
  request. A *confirmed* failure (TMDb genuinely has nothing, or a prior
  attempt already marked it so — see `ImageCache.store_person/2`) gets a
  `cache-control` header so an unauthenticated caller can't force a
  re-attempt, and thus a fresh outbound TMDb call, on every view forever.
  """
  def show(conn, %{"item_id" => item_id, "image_type" => image_type}) do
    item_id = Id.coerce(item_id)

    case ImageCache.path_for(item_id, image_type) do
      {:ok, path} ->
        serve(conn, path)

      :error ->
        case fetch_person_headshot(item_id, image_type) do
          {:ok, path} -> serve(conn, path)
          :confirmed_miss -> not_found(conn, cacheable: true)
          :error -> not_found(conn, cacheable: false)
        end
    end
  end

  def show(conn, _params) do
    not_found(conn, cacheable: false)
  end

  # The concurrency gate wraps the whole lookup+fetch, not just the download:
  # cheap to do, and it means a non-"primary" request or a cap rejection
  # never even reaches a DB lookup.
  defp fetch_person_headshot(person_id, image_type) do
    with true <- String.downcase(to_string(image_type)) == "primary",
         true <- acquire_headshot_slot() do
      try do
        do_fetch_person_headshot(person_id)
      after
        release_headshot_slot()
      end
    else
      _ -> :error
    end
  end

  # Two concurrent requests for the same uncached face can both download;
  # the loser hits images_person_id_type_unique_index and store_person/2
  # returns {:error, changeset} (not a raise) — self-healing, since the
  # winner's row already makes the next request a cache hit.
  defp do_fetch_person_headshot(person_id) do
    with %Person{profile_path: profile_path} when is_binary(profile_path) <-
           Repo.get(Person, person_id),
         url when is_binary(url) <- provider().image_url(profile_path, :profile) do
      case ImageCache.store_person(person_id, url) do
        {:ok, path} -> {:ok, path}
        # store_person/2 has either just persisted a "don't retry" marker,
        # or hit one that already existed — either way this is a durable
        # "no photo", safe to cache client-side.
        {:error, _reason} -> :confirmed_miss
      end
    else
      _ -> :error
    end
  end

  defp provider, do: Application.get_env(:hivefin, :metadata_provider, TMDB)

  # :counters instead of a GenServer/ETS table: a counters ref lives
  # independently of any owning process, so persistent_term is enough to
  # share one across requests with nothing to supervise. A lazy-init race on
  # the very first requests could momentarily create two refs; harmless —
  # whichever one "wins" future persistent_term reads is used consistently
  # from then on, and the cap is an advisory throttle, not a hard invariant.
  defp acquire_headshot_slot do
    ref = headshot_gate()
    :counters.add(ref, 1, 1)

    if :counters.get(ref, 1) <= @max_concurrent_headshot_fetches do
      true
    else
      :counters.sub(ref, 1, 1)
      false
    end
  end

  defp release_headshot_slot do
    :counters.sub(headshot_gate(), 1, 1)
  end

  defp headshot_gate do
    case :persistent_term.get(@headshot_gate_key, nil) do
      nil ->
        ref = :counters.new(1, [])
        :persistent_term.put(@headshot_gate_key, ref)
        ref

      ref ->
        ref
    end
  end

  defp serve(conn, path) do
    conn
    |> put_resp_content_type(content_type(path))
    |> put_resp_header("cache-control", "public, max-age=86400")
    |> send_file(200, path)
  end

  defp not_found(conn, cacheable: cacheable?) do
    conn
    |> maybe_cache_control(cacheable?)
    |> put_status(:not_found)
    |> json(%{"error" => "image_not_found"})
  end

  # Only a confirmed failure (persisted negative-cache marker) gets this —
  # a transient miss (concurrency cap, no profile_path yet) must stay
  # uncached so the very next view can succeed once conditions change.
  defp maybe_cache_control(conn, true),
    do: put_resp_header(conn, "cache-control", "public, max-age=3600")

  defp maybe_cache_control(conn, false), do: conn

  defp content_type(path) do
    case path |> Path.extname() |> String.downcase() do
      ".png" -> "image/png"
      ".webp" -> "image/webp"
      ".gif" -> "image/gif"
      _ -> "image/jpeg"
    end
  end
end
