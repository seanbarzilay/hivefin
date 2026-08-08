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
  # ceiling on plain HTTP/1.1 (this deployment's default — see
  # config/runtime.exs), so one legitimate user opening one cast page is
  # very unlikely to ever get capped there — only genuine bursts (many
  # concurrent pageviews, or abuse of this unauthenticated route) are.
  # Behind a TLS-terminating HTTP/2 proxy there's no 6-socket ceiling, so a
  # single cold 40-cast page COULD exceed 10 — not a correctness problem,
  # a capped request just 404s uncached and self-heals on the next view.
  @max_concurrent_headshot_fetches 10
  @headshot_gate_key {__MODULE__, :headshot_fetch_gate}

  # A confirmed miss is durable: it only changes when a metadata refresh
  # changes profile_path, which also clears the server-side marker. Worth an
  # hour of client-side caching — that's the whole point of the marker, since
  # this route is unauthenticated.
  @confirmed_miss_cache_control "public, max-age=3600"

  # A transient miss must not be cached at all. Explicit rather than relying
  # on whatever default the pipeline happens to set: this controller owns the
  # decision, and the server is ready to retry on the very next request.
  @transient_miss_cache_control "no-store"

  @doc """
  Serves a cached item or person image (`Primary` / `Backdrop`) when present.

  Headshots are fetched lazily: on a cache miss for a person id with a
  non-nil `profile_path`, this fetches the image from TMDb on the spot,
  caches it, and serves it — the only place a person headshot is ever
  downloaded (metadata refresh never fetches them, see `Metadata.Worker`).

  Returns 404 when there's nothing cached and nothing to lazily fetch
  (missing item image, or a person with no `profile_path`), and also on a
  failed fetch — a broken `profile_path` or a TMDb error must never 500 this
  request. A *confirmed* miss (TMDb genuinely has nothing, or a prior attempt
  already marked it so — see `ImageCache.permanent_failure?/1`) gets a long
  `cache-control` so an unauthenticated caller can't force a re-attempt, and
  thus a fresh outbound TMDb call, on every view forever. A *transient*
  failure gets `no-store` instead: the server is ready to retry it on the
  very next request, so the browser must not be holding a stale negative
  cache that stops it from ever asking again.
  """
  def show(conn, %{"item_id" => item_id, "image_type" => image_type}) do
    item_id = Id.coerce(item_id)

    case ImageCache.path_for(item_id, image_type) do
      {:ok, path} ->
        serve(conn, path)

      :error ->
        case fetch_person_headshot(item_id, image_type) do
          {:ok, path} -> serve(conn, path)
          :confirmed_miss -> not_found(conn, @confirmed_miss_cache_control)
          :transient_miss -> not_found(conn, @transient_miss_cache_control)
        end
    end
  end

  def show(conn, _params) do
    not_found(conn, @transient_miss_cache_control)
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
      # Not a person image request at all, or the concurrency cap rejected
      # this one. Neither says anything durable about the image.
      _ -> :transient_miss
    end
  end

  # Two concurrent requests for the same uncached face can both attempt a
  # download; the loser's own Repo.insert hits
  # images_person_id_type_unique_index. store_person/2 handles that case
  # explicitly (re-reads and returns the winner's row) rather than treating
  # it as a failure, so the LOSER's own call already returns the winner's
  # path — not just the next request.
  defp do_fetch_person_headshot(person_id) do
    with %Person{profile_path: profile_path} when is_binary(profile_path) <-
           Repo.get(Person, person_id),
         url when is_binary(url) <- provider().image_url(profile_path, :profile) do
      case ImageCache.store_person(person_id, url) do
        {:ok, path} -> {:ok, path}
        {:error, reason} -> miss_kind(reason)
      end
    else
      # The person exists and has no profile_path at all: the strongest
      # confirmed miss there is — we know there's no photo without asking
      # anyone, and it stays true until a refresh sets one (the same event
      # that clears a server-side marker).
      %Person{} ->
        :confirmed_miss

      # Not a person id at all (an item whose image simply isn't cached yet),
      # or the provider produced no URL. Nothing durable here.
      _ ->
        :transient_miss
    end
  end

  # The one classification, owned by ImageCache: the same predicate decides
  # whether the server persists a "don't retry" marker and how long the
  # browser is told to cache this 404. Two parallel lists is exactly how
  # these drifted apart before — the server stopped marking transient
  # failures while this endpoint kept telling browsers they were durable.
  defp miss_kind(reason) do
    if ImageCache.permanent_failure?(reason), do: :confirmed_miss, else: :transient_miss
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

  defp not_found(conn, cache_control) do
    conn
    |> put_resp_header("cache-control", cache_control)
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
