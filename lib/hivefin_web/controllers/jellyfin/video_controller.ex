defmodule HivefinWeb.Jellyfin.VideoController do
  use HivefinWeb, :controller

  require Logger

  alias Hivefin.Library.LibraryContext
  alias Hivefin.Playback.{Session, StreamToken, Supervisor}

  @doc """
  Progressive DirectPlay (`Static=true`), FFmpeg remux (`Static=false`), or
  progressive transcode (`Static=false&Transcode=true`).

  Auth: stream token via `api_key` or `Tag` query params (not MediaBrowser header).
  """
  def stream(conn, %{"item_id" => item_id} = params) do
    token = params["api_key"] || params["Tag"] || params["apiKey"]

    with {:ok, claims} <- StreamToken.verify(token || ""),
         true <- claims.item_id == item_id,
         true <- media_source_matches?(claims, params),
         {:ok, path} <- LibraryContext.media_path_for_item(item_id, claims) do
      cond do
        static_request?(params) ->
          send_media_file(conn, path)

        transcode_request?(params) ->
          stream_ffmpeg(conn, path, params, :transcode)

        true ->
          stream_ffmpeg(conn, path, params, :remux)
      end
    else
      {:error, :expired} ->
        conn |> put_status(:unauthorized) |> json(%{"error" => "token_expired"})

      {:error, :invalid} ->
        conn |> put_status(:unauthorized) |> json(%{"error" => "unauthorized"})

      {:error, :missing} ->
        conn |> put_status(:unauthorized) |> json(%{"error" => "unauthorized"})

      false ->
        conn |> put_status(:forbidden) |> json(%{"error" => "forbidden"})

      {:error, :forbidden} ->
        conn |> put_status(:forbidden) |> json(%{"error" => "forbidden"})

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{"error" => "not_found"})
    end
  end

  @doc """
  Legacy path kept for older clients. Progressive MPEG-TS transcode (not HLS).

  Prefer `TranscodingUrl` from PlaybackInfo (`stream.ts?...&Transcode=true`).
  Concurrent session limit exhausted → 503.
  """
  def master_m3u8(conn, %{"item_id" => item_id} = params) do
    token = params["api_key"] || params["Tag"] || params["apiKey"]

    with {:ok, claims} <- StreamToken.verify(token || ""),
         true <- claims.item_id == item_id,
         true <- media_source_matches?(claims, params),
         {:ok, path} <- LibraryContext.media_path_for_item(item_id, claims) do
      stream_ffmpeg(conn, path, params, :transcode)
    else
      {:error, :expired} ->
        conn |> put_status(:unauthorized) |> json(%{"error" => "token_expired"})

      {:error, :invalid} ->
        conn |> put_status(:unauthorized) |> json(%{"error" => "unauthorized"})

      {:error, :missing} ->
        conn |> put_status(:unauthorized) |> json(%{"error" => "unauthorized"})

      false ->
        conn |> put_status(:forbidden) |> json(%{"error" => "forbidden"})

      {:error, :forbidden} ->
        conn |> put_status(:forbidden) |> json(%{"error" => "forbidden"})

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{"error" => "not_found"})
    end
  end

  defp stream_ffmpeg(conn, path, params, mode) when mode in [:remux, :transcode] do
    session_id = play_session_id(params)

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

  defp media_source_matches?(claims, params) do
    case params["MediaSourceId"] || params["mediaSourceId"] do
      nil -> true
      id -> id == claims.media_source_id
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
