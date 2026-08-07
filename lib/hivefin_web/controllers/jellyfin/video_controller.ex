defmodule HivefinWeb.Jellyfin.VideoController do
  use HivefinWeb, :controller

  require Logger

  alias Hivefin.Accounts
  alias Hivefin.Accounts.User
  alias Hivefin.Jellyfin.Id
  alias Hivefin.Library.{LibraryContext, MediaSource}
  alias Hivefin.Playback.{Session, StreamToken, Supervisor}


  @doc """
  Progressive DirectPlay (`Static=true`), FFmpeg remux (`Static=false`), or
  progressive transcode (`Static=false&Transcode=true`).

  Path `:item_id` may be either the **item** id or the **media source** id.
  jellyfin-vue builds `/Videos/{mediaSourceId}/stream.{container}?api_key={accessToken}`.

  Auth via query `api_key` / `Tag` / `apiKey`:
  - signed stream token (PlaybackInfo DirectStreamUrl), or
  - user access token (jellyfin-vue direct stream convention)
  """
  def stream(conn, %{"item_id" => path_id} = params) do
    case authorize_stream(path_id, params) do
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
  Legacy path kept for older clients. Progressive MPEG-TS transcode (not HLS).

  Prefer `TranscodingUrl` from PlaybackInfo (`stream.ts?...&Transcode=true`).
  Concurrent session limit exhausted → 503.
  """
  def master_m3u8(conn, %{"item_id" => path_id} = params) do
    case authorize_stream(path_id, params) do
      {:ok, claims, path} ->
        conn
        |> assign(:stream_claims, claims)
        |> then(&stream_ffmpeg(&1, path, params, :transcode))

      {:error, reason} ->
        stream_error(conn, reason)
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
  defp authorize_stream(path_id, params) do
    token = params["api_key"] || params["Tag"] || params["apiKey"] || ""

    case StreamToken.verify(token) do
      {:ok, claims} ->
        authorize_stream_token(path_id, params, claims)

      {:error, :expired} ->
        {:error, :expired}

      {:error, _} ->
        authorize_access_token(path_id, params, token)
    end
  end

  defp authorize_stream_token(path_id, params, claims) do
    path_id = Id.coerce(path_id)
    query_msid = Id.coerce(params["MediaSourceId"] || params["mediaSourceId"])
    claim_item = Id.coerce(claims.item_id)
    claim_msid = Id.coerce(claims.media_source_id)
    claims = %{claims | item_id: claim_item, media_source_id: claim_msid}

    cond do
      claim_item == path_id and (is_nil(query_msid) or query_msid == claim_msid) ->
        with {:ok, path} <- LibraryContext.media_path_for_item(claim_item, claims) do
          {:ok, claims, path}
        end

      claim_msid == path_id ->
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

        case LibraryContext.get_media_source(source_id) do
          %MediaSource{id: msid, item_id: item_id} ->
            item_id = Id.coerce(item_id)
            msid = Id.coerce(msid)

            if path_id == msid or path_id == item_id do
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
          %{id: session_id, mode: :remux, input_path: path}

        :transcode ->
          %{
            id: session_id,
            mode: :transcode,
            input_path: path,
            format: "mpegts",
            height: height_from_params(params)
          }
      end

    case Supervisor.start_session(attrs) do
      {:ok, pid} ->
        stream_pipe(conn, pid, "video/mp2t")

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

  defp stream_pipe(conn, pid, content_type) do
    Session.attach_consumer(pid, self())

    try do
      case Session.await_ready(pid, 15_000) do
        {:ok, _} ->
          conn =
            conn
            |> put_resp_content_type(content_type)
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
                |> put_resp_content_type(content_type)
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
    content_type = MIME.from_path(path)

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
end
