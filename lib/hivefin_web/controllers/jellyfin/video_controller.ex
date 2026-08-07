defmodule HivefinWeb.Jellyfin.VideoController do
  use HivefinWeb, :controller

  require Logger

  alias Hivefin.Accounts
  alias Hivefin.Accounts.User
  alias Hivefin.Jellyfin.Id
  alias Hivefin.Library.{LibraryContext, MediaSource}
  alias Hivefin.Playback.FFmpeg.Args
  alias Hivefin.Playback.Hls.Playlist
  alias Hivefin.Playback.{Session, StreamToken, Supervisor}

  @doc """
  Progressive DirectPlay (`Static=true`), FFmpeg remux (`Static=false`), or
  progressive transcode (`Static=false&Transcode=true`).

  Path `:item_id` may be either the **item** id or the **media source** id.
  jellyfin-vue builds `/Videos/{mediaSourceId}/stream.{container}?api_key={accessToken}`.

  Auth, in order:
  - signed stream token in query `api_key` / `Tag` / `apiKey` (PlaybackInfo
    DirectStreamUrl), or
  - user access token in the same query params (jellyfin-vue convention), or
  - user access token from the MediaBrowser `Authorization` /
    `X-Emby-Authorization` / `X-Emby-Token` header (Android ExoPlayer, which
    never puts the token in the URL)
  """
  def stream(conn, %{"item_id" => path_id} = params) do
    case authorize_stream(conn, path_id, params) do
      {:ok, claims, path} ->
        conn = assign(conn, :stream_claims, claims)

        cond do
          static_request?(params) ->
            send_media_file(conn, path)

          transcode_request?(params) ->
            stream_ffmpeg(conn, path, params, :transcode)

          true ->
            stream_ffmpeg(conn, path, params, :remux)
        end

      {:error, reason} ->
        stream_error(conn, reason)
    end
  end

  @doc """
  HLS master playlist for remux/transcode.

  jellyfin-vue always feeds non-DirectPlay URLs into hls.js, so PlaybackInfo
  TranscodingUrl points here (`TranscodingSubProtocol=hls`).
  Concurrent session limit exhausted → 503.
  """
  def master_m3u8(conn, %{"item_id" => path_id} = params) do
    case authorize_stream(conn, path_id, params) do
      {:ok, claims, path} ->
        conn = assign(conn, :stream_claims, claims)
        mode = if transcode_request?(params), do: :transcode, else: :remux
        serve_hls_playlist(conn, path, params, mode)

      {:error, reason} ->
        stream_error(conn, reason)
    end
  end

  # With a VOD playlist the client can legitimately request a segment
  # slightly ahead of the encoder, so poll instead of 404ing immediately.
  # The encoder runs ~2.8x realtime, so normal sequential playback stays
  # ahead and this returns on the first check almost always.
  #
  # Known limitation (documented, not solved here): seeking beyond the
  # encoder's current position stalls for the full cap below, because we
  # transcode strictly forward from 0. Upstream Jellyfin restarts ffmpeg at
  # the requested offset for a seek; we do not.
  @segment_wait_poll_ms 100
  @segment_wait_cap_ms 20_000

  @doc """
  Serves an HLS media segment produced by an active FFmpeg session.
  """
  def hls_segment(
        conn,
        %{"item_id" => path_id, "session_id" => session_id, "file" => file} = params
      ) do
    case authorize_stream(conn, path_id, params) do
      {:ok, _claims, _path} ->
        deadline = System.monotonic_time(:millisecond) + @segment_wait_cap_ms

        case await_segment_path(session_id, file, deadline) do
          {:ok, segment} ->
            _ = Session.keepalive(session_id)

            conn
            |> put_resp_content_type(segment_content_type(file), nil)
            |> put_resp_header("cache-control", "no-cache")
            |> send_file(200, segment)

          {:error, :invalid} ->
            conn |> put_status(:bad_request) |> json(%{"error" => "invalid_segment"})

          {:error, _} ->
            conn |> put_status(:not_found) |> json(%{"error" => "segment_not_found"})
        end

      {:error, reason} ->
        stream_error(conn, reason)
    end
  end

  defp await_segment_path(session_id, file, deadline_ms) do
    case Session.segment_path(session_id, file) do
      {:ok, _} = ok ->
        ok

      {:error, :invalid} = err ->
        err

      {:error, :not_found} = err ->
        if System.monotonic_time(:millisecond) >= deadline_ms do
          err
        else
          Process.sleep(@segment_wait_poll_ms)
          await_segment_path(session_id, file, deadline_ms)
        end
    end
  end

  defp stream_error(conn, :expired),
    do: conn |> put_status(:unauthorized) |> json(%{"error" => "token_expired"})

  defp stream_error(conn, :invalid),
    do: conn |> put_status(:unauthorized) |> json(%{"error" => "unauthorized"})

  defp stream_error(conn, :missing),
    do: conn |> put_status(:unauthorized) |> json(%{"error" => "unauthorized"})

  defp stream_error(conn, :unauthorized),
    do: conn |> put_status(:unauthorized) |> json(%{"error" => "unauthorized"})

  defp stream_error(conn, :forbidden),
    do: conn |> put_status(:forbidden) |> json(%{"error" => "forbidden"})

  defp stream_error(conn, :not_found),
    do: conn |> put_status(:not_found) |> json(%{"error" => "not_found"})

  defp stream_error(conn, _),
    do: conn |> put_status(:unauthorized) |> json(%{"error" => "unauthorized"})

  # Resolves path id (item OR media source) + token (stream token OR access token).
  defp authorize_stream(conn, path_id, params) do
    query_token = params["api_key"] || params["Tag"] || params["apiKey"] || ""

    case StreamToken.verify(query_token) do
      {:ok, claims} ->
        authorize_stream_token(path_id, params, claims)

      {:error, :expired} ->
        {:error, :expired}

      {:error, _} ->
        # Not a signed stream token. Android ExoPlayer deliberately keeps the
        # token out of the URL ("we don't pass the access token in the URL",
        # jellyfin-android AppModule) and sends `Authorization: MediaBrowser
        # ... Token="..."` instead, so also accept header credentials — as
        # real Jellyfin does on every endpoint.
        [query_token, header_token(conn)]
        |> Enum.filter(&(is_binary(&1) and &1 != ""))
        |> Enum.uniq()
        |> try_access_tokens(path_id, params)
    end
  end

  defp try_access_tokens([], _path_id, _params), do: {:error, :unauthorized}

  defp try_access_tokens(tokens, path_id, params) do
    Enum.reduce_while(tokens, {:error, :unauthorized}, fn token, _last ->
      case authorize_access_token(path_id, params, token) do
        {:ok, _claims, _path} = ok -> {:halt, ok}
        error -> {:cont, error}
      end
    end)
  end

  defp header_token(conn) do
    case HivefinWeb.Plugs.JellyfinAuth.resolve_token(conn) do
      {:ok, token} -> token
      :error -> nil
    end
  end

  defp authorize_stream_token(path_id, params, claims) do
    path_id = Id.coerce(path_id)
    query_msid = Id.coerce(params["MediaSourceId"] || params["mediaSourceId"])
    claim_item = Id.coerce(claims.item_id)
    claim_msid = Id.coerce(claims.media_source_id)
    claims = %{claims | item_id: claim_item, media_source_id: claim_msid}

    # MediaSourceId may be the real source UUID or the item id (JF primary-source id).
    msid_ok? =
      is_nil(query_msid) or query_msid == claim_msid or query_msid == claim_item

    cond do
      claim_item == path_id and msid_ok? ->
        with {:ok, path} <- LibraryContext.media_path_for_item(claim_item, claims) do
          {:ok, claims, path}
        end

      claim_msid == path_id and msid_ok? ->
        with {:ok, path} <- LibraryContext.media_path_for_item(claim_item, claims) do
          {:ok, claims, path}
        end

      true ->
        {:error, :forbidden}
    end
  end

  defp authorize_access_token(path_id, params, token) do
    case Accounts.get_user_by_token(token) do
      %User{id: user_id} ->
        path_id = Id.coerce(path_id)

        source_id =
          Id.coerce(params["MediaSourceId"] || params["mediaSourceId"] || path_id)

        source =
          LibraryContext.get_media_source(source_id) ||
            LibraryContext.first_media_source_for_item(source_id) ||
            LibraryContext.first_media_source_for_item(path_id)

        case source do
          %MediaSource{id: msid, item_id: item_id} ->
            item_id = Id.coerce(item_id)
            msid = Id.coerce(msid)

            if path_id == msid or path_id == item_id or source_id == item_id do
              claims = %{user_id: user_id, item_id: item_id, media_source_id: msid}

              with {:ok, path} <- LibraryContext.media_path_for_item(item_id, claims) do
                {:ok, claims, path}
              end
            else
              {:error, :forbidden}
            end

          nil ->
            case LibraryContext.get_item(path_id) do
              nil -> {:error, :not_found}
              _item -> {:error, :forbidden}
            end
        end

      nil ->
        {:error, :unauthorized}
    end
  end

  defp stream_ffmpeg(conn, path, params, mode) when mode in [:remux, :transcode] do
    client_session_id = play_session_id(params)

    # Bind registry key to user + media source + path + mode so a recycled
    # client PlaySessionId cannot share an FFmpeg process across items/users.
    claims = conn.assigns[:stream_claims] || %{}

    session_id =
      Supervisor.registry_id(client_session_id, %{
        user_id: Map.get(claims, :user_id),
        media_source_id:
          Map.get(claims, :media_source_id) ||
            params["MediaSourceId"] ||
            params["mediaSourceId"],
        mode: mode,
        input_path: path
      })

    attrs =
      case mode do
        :remux ->
          %{id: session_id, mode: :remux, input_path: path, format: "mp4"}

        :transcode ->
          %{
            id: session_id,
            mode: :transcode,
            input_path: path,
            format: "mp4",
            height: height_from_params(params)
          }
      end

    case Supervisor.start_session(attrs) do
      {:ok, pid} ->
        stream_pipe(conn, pid, "video/mp4")

      {:error, :busy} ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{"error" => "too_many_transcodes", "message" => "Transcode capacity reached"})

      {:error, reason} ->
        Logger.warning("#{mode} session failed: #{inspect(reason)}")
        error_key = if mode == :remux, do: "remux_failed", else: "transcode_failed"

        conn
        |> put_status(:internal_server_error)
        |> json(%{"error" => error_key})
    end
  end

  defp serve_hls_playlist(conn, path, params, mode) when mode in [:remux, :transcode] do
    claims = conn.assigns[:stream_claims] || %{}
    client_session_id = play_session_id(params)

    session_id =
      Supervisor.registry_id(client_session_id, %{
        user_id: Map.get(claims, :user_id),
        media_source_id:
          Map.get(claims, :media_source_id) ||
            params["MediaSourceId"] ||
            params["mediaSourceId"],
        mode: mode,
        input_path: path
      })

    attrs =
      case mode do
        :remux ->
          %{id: session_id, mode: :remux, input_path: path, format: "hls"}

        :transcode ->
          %{
            id: session_id,
            mode: :transcode,
            input_path: path,
            format: "hls",
            height: height_from_params(params)
          }
      end

    case Supervisor.start_session(attrs) do
      {:ok, pid} ->
        token = params["api_key"] || params["Tag"] || params["apiKey"] || ""
        # Relative to master.m3u8 so hls.js resolves against the API host,
        # not the jellyfin-vue page origin (different port → 404).
        result =
          case Playlist.build(
                 source_runtime_seconds(claims),
                 Args.hls_segment_seconds(),
                 session_id,
                 token
               ) do
            {:ok, body} ->
              # We build the full segment list ourselves from the known
              # runtime, so we only need to know ffmpeg started — no need to
              # wait for a minimum segment count on disk (hls_segment/2
              # polls for segments that aren't written yet).
              case Session.await_ready(pid, 30_000) do
                {:ok, _} ->
                  _ = Session.keepalive(pid)
                  {:ok, body}

                error ->
                  error
              end

            :fallback ->
              Logger.debug(
                "HLS: unknown/zero source runtime for session #{session_id}; " <>
                  "falling back to ffmpeg's EVENT playlist"
              )

              case await_hls_playlist(pid, 30_000) do
                {:ok, ffmpeg_body} ->
                  _ = Session.keepalive(pid)
                  {:ok, rewrite_hls_playlist(ffmpeg_body, session_id, token)}

                error ->
                  error
              end
          end

        send_hls_ready_result(conn, result)

      {:error, :busy} ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{"error" => "too_many_transcodes", "message" => "Transcode capacity reached"})

      {:error, reason} ->
        Logger.warning("hls #{mode} session failed: #{inspect(reason)}")
        conn |> put_status(:internal_server_error) |> json(%{"error" => "hls_failed"})
    end
  end

  defp send_hls_ready_result(conn, {:ok, body}) do
    conn
    |> put_resp_content_type("application/vnd.apple.mpegurl", nil)
    |> put_resp_header("cache-control", "no-cache")
    |> put_resp_header("access-control-expose-headers", "content-type")
    |> send_resp(200, body)
  end

  defp send_hls_ready_result(conn, {:error, :timeout}) do
    conn |> put_status(:gateway_timeout) |> json(%{"error" => "session_timeout"})
  end

  defp send_hls_ready_result(conn, {:error, reason}) do
    Logger.warning("hls session not ready: #{inspect(reason)}")
    conn |> put_status(:internal_server_error) |> json(%{"error" => "session_failed"})
  end

  # Runtime (seconds) of the media source backing this session, or `nil` when
  # unknown — `Playlist.build/4` falls back to ffmpeg's own playlist in that
  # case rather than emit a broken VOD one.
  defp source_runtime_seconds(claims) do
    item_id = Map.get(claims, :item_id)
    media_source_id = Map.get(claims, :media_source_id)

    source =
      (is_binary(media_source_id) && LibraryContext.get_media_source(media_source_id)) ||
        (is_binary(item_id) && LibraryContext.first_media_source_for_item(item_id))

    case source do
      %MediaSource{duration_ticks: ticks} when is_integer(ticks) and ticks > 0 ->
        ticks / 10_000_000

      _ ->
        nil
    end
  end

  # Prefer three segments so hls.js has buffer before the first ends
  # (short EVENT playlists often stall after frag 0 on Android WebView).
  @hls_min_segments 3

  # Wait until the session is ready and the playlist lists enough segments.
  defp await_hls_playlist(pid, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    case Session.await_ready(pid, timeout_ms) do
      {:ok, :hls} ->
        poll_playlist_body(pid, deadline)

      {:ok, other} ->
        {:error, {:not_hls, other}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp poll_playlist_body(pid, deadline) do
    now = System.monotonic_time(:millisecond)

    if now >= deadline do
      {:error, :timeout}
    else
      info = Session.info(pid)
      path = info.playlist_path

      case is_binary(path) && File.read(path) do
        {:ok, body} ->
          if hls_segment_count(body) >= @hls_min_segments do
            {:ok, body}
          else
            Process.sleep(150)
            poll_playlist_body(pid, deadline)
          end

        _ ->
          Process.sleep(150)
          poll_playlist_body(pid, deadline)
      end
    end
  end

  defp hls_segment_count(body) when is_binary(body) do
    body
    |> String.split("\n")
    |> Enum.count(fn line ->
      t = String.trim(line)
      t != "" and not String.starts_with?(t, "#")
    end)
  end

  defp rewrite_hls_playlist(body, session_id, token) when is_binary(body) do
    token_q = URI.encode_www_form(token)
    hls_prefix = "hls/#{session_id}"

    rewritten =
      body
      # Never inject EXT-X-START — on Android WebView/hls.js it causes live-edge
      # seeks / 00:00 stalls. With EVENT + enough initial segs, start at 0 is natural.
      |> strip_hls_start_tag()
      # fMP4 init segment referenced by EXT-X-MAP must be under our session path.
      |> rewrite_hls_map_uri(hls_prefix, token_q)
      |> String.split("\n")
      |> Enum.map(fn line ->
        trimmed = String.trim(line)

        cond do
          trimmed == "" or String.starts_with?(trimmed, "#") ->
            line

          Regex.match?(~r/^(seg_\d+\.(ts|m4s)|init\.mp4)$/i, Path.basename(trimmed)) ->
            name = Path.basename(trimmed)
            # Path-relative to /Videos/:id/master.m3u8 → /Videos/:id/hls/:session/:file
            "#{hls_prefix}/#{name}?api_key=#{token_q}"

          true ->
            line
        end
      end)
      |> Enum.join("\n")

    # HLS clients are picky about a trailing newline after the last segment line.
    if String.ends_with?(rewritten, "\n"), do: rewritten, else: rewritten <> "\n"
  end

  # #EXT-X-MAP:URI="init.mp4" → URI="hls/<session>/init.mp4?api_key=..."
  defp rewrite_hls_map_uri(body, hls_prefix, token_q) do
    Regex.replace(~r/#EXT-X-MAP:URI="([^"]+)"/i, body, fn _full, uri ->
      name = uri |> String.split("?") |> hd() |> Path.basename()
      ~s(#EXT-X-MAP:URI="#{hls_prefix}/#{name}?api_key=#{token_q}")
    end)
  end

  defp strip_hls_start_tag(body) do
    String.replace(body, ~r/#EXT-X-START:[^\r\n]*\r?\n/i, "")
  end

  defp segment_content_type(file) do
    case Path.extname(file) |> String.downcase() do
      # video/mp4 for both — some WebViews reject video/iso.segment for MSE.
      ".m4s" -> "video/mp4"
      ".mp4" -> "video/mp4"
      _ -> "video/mp2t"
    end
  end

  defp stream_pipe(conn, pid, content_type) do
    Session.attach_consumer(pid, self())

    try do
      case Session.await_ready(pid, 15_000) do
        {:ok, _} ->
          conn =
            conn
            |> put_resp_content_type(content_type, nil)
            |> send_chunked(200)

          pump_chunks(conn, pid)

        {:error, :timeout} ->
          conn
          |> put_status(:gateway_timeout)
          |> json(%{"error" => "session_timeout"})

        {:error, reason} ->
          Logger.warning("session not ready: #{inspect(reason)}")

          case Session.read_chunk(pid, 500) do
            {:ok, data} when byte_size(data) > 0 ->
              conn =
                conn
                |> put_resp_content_type(content_type, nil)
                |> send_chunked(200)

              case chunk(conn, data) do
                {:ok, conn} -> pump_chunks(conn, pid)
                {:error, _} -> conn
              end

            _ ->
              conn
              |> put_status(:internal_server_error)
              |> json(%{"error" => "session_failed"})
          end
      end
    after
      Session.stop(pid)
    end
  end

  defp pump_chunks(conn, pid) do
    case Session.read_chunk(pid, 10_000) do
      {:ok, data} ->
        case chunk(conn, data) do
          {:ok, conn} ->
            pump_chunks(conn, pid)

          {:error, :closed} ->
            conn
        end

      {:error, :closed} ->
        conn

      {:error, :timeout} ->
        conn

      {:error, _} ->
        conn
    end
  end

  defp play_session_id(params) do
    cond do
      is_binary(params["PlaySessionId"]) and params["PlaySessionId"] != "" ->
        params["PlaySessionId"]

      is_binary(params["playSessionId"]) and params["playSessionId"] != "" ->
        params["playSessionId"]

      true ->
        base =
          params["MediaSourceId"] ||
            params["mediaSourceId"] ||
            "anon"

        "sess-#{base}-#{System.unique_integer([:positive])}"
    end
  end

  defp height_from_params(params) do
    case params["MaxHeight"] || params["maxHeight"] || params["Height"] do
      n when is_integer(n) and n > 0 ->
        n

      n when is_binary(n) ->
        case Integer.parse(n) do
          {i, _} when i > 0 -> i
          _ -> 720
        end

      _ ->
        720
    end
  end

  # Static=true (default for DirectPlay URLs) serves the original file.
  # Static=false is remux or transcode progressive MPEG-TS.
  defp static_request?(params) do
    case params["Static"] || params["static"] do
      v when v in [false, "false", "False", "0", 0] -> false
      _ -> true
    end
  end

  defp transcode_request?(params) do
    case params["Transcode"] || params["transcode"] do
      v when v in [true, "true", "True", "1", 1] -> true
      _ -> false
    end
  end

  defp send_media_file(conn, path) do
    {:ok, %{size: size}} = File.stat(path)
    content_type = media_content_type(path)

    conn =
      conn
      |> put_resp_header("accept-ranges", "bytes")
      |> put_resp_header("content-type", content_type)
      |> put_resp_header("content-length", Integer.to_string(size))

    case get_req_header(conn, "range") do
      ["bytes=" <> range] ->
        serve_range(conn, path, range, size)

      _ ->
        conn
        |> send_file(200, path)
    end
  end

  defp serve_range(conn, path, range, file_size) do
    case parse_byte_range(range, file_size) do
      {:ok, range_start, range_end} ->
        length = range_end - range_start + 1

        conn
        |> put_resp_header("content-range", "bytes #{range_start}-#{range_end}/#{file_size}")
        |> put_resp_header("content-length", Integer.to_string(length))
        |> send_file(206, path, range_start, length)

      :unsatisfiable ->
        conn
        |> put_resp_header("content-range", "bytes */#{file_size}")
        |> send_resp(416, "")

      :error ->
        conn
        |> send_file(200, path)
    end
  end

  defp parse_byte_range(_range, 0), do: :error

  defp parse_byte_range(range, file_size) when is_binary(range) do
    # Single range only; multi-range not supported.
    range = range |> String.split(",", parts: 2) |> hd() |> String.trim()

    cond do
      String.starts_with?(range, "-") ->
        case Integer.parse(String.trim_leading(range, "-")) do
          {last, ""} when last > 0 and last <= file_size ->
            {:ok, file_size - last, file_size - 1}

          _ ->
            :error
        end

      true ->
        case Integer.parse(range) do
          {first, "-"} when first >= 0 and first < file_size ->
            {:ok, first, file_size - 1}

          {first, "-" <> rest} when first >= 0 and first < file_size ->
            case Integer.parse(rest) do
              {last, ""} when last >= first ->
                {:ok, first, min(last, file_size - 1)}

              _ ->
                :error
            end

          {first, "-" <> _} when first >= file_size ->
            :unsatisfiable

          _ ->
            :error
        end
    end
  end

  defp parse_byte_range(_, _), do: :error

  defp media_content_type(path) do
    case Path.extname(path) |> String.downcase() do
      ".mkv" ->
        "video/x-matroska"

      ".mp4" ->
        "video/mp4"

      ".m4v" ->
        "video/mp4"

      ".webm" ->
        "video/webm"

      ".ts" ->
        "video/mp2t"

      ".m2ts" ->
        "video/mp2t"

      ".avi" ->
        "video/x-msvideo"

      other ->
        case MIME.from_path(path) do
          "application/octet-stream" when other != "" -> "video/mp4"
          type -> type
        end
    end
  end
end
