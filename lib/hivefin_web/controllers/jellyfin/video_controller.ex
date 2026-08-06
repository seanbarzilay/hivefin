defmodule HivefinWeb.Jellyfin.VideoController do
  use HivefinWeb, :controller

  alias Hivefin.Library.LibraryContext
  alias Hivefin.Playback.StreamToken

  @doc """
  Progressive DirectPlay stream with optional HTTP Range.

  Auth: stream token via `api_key` or `Tag` query params (not MediaBrowser header).
  """
  def stream(conn, %{"item_id" => item_id} = params) do
    token = params["api_key"] || params["Tag"] || params["apiKey"]

    with {:ok, claims} <- StreamToken.verify(token || ""),
         true <- claims.item_id == item_id,
         true <- media_source_matches?(claims, params),
         {:ok, path} <- LibraryContext.media_path_for_item(item_id, claims) do
      if static_request?(params) do
        send_media_file(conn, path)
      else
        # Remux / non-static path — FFmpeg runner is Task 8
        conn
        |> put_status(:not_implemented)
        |> json(%{
          "error" => "remux_not_implemented",
          "message" => "DirectStream remux lands in Task 8"
        })
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
  HLS / transcode master playlist placeholder until Task 8.
  """
  def master_m3u8(conn, params) do
    token = params["api_key"] || params["Tag"] || params["apiKey"]

    case StreamToken.verify(token || "") do
      {:ok, _} ->
        conn
        |> put_status(:not_implemented)
        |> json(%{
          "error" => "transcode_not_implemented",
          "message" => "Transcode runner lands in Task 8"
        })

      {:error, _} ->
        conn |> put_status(:unauthorized) |> json(%{"error" => "unauthorized"})
    end
  end

  defp media_source_matches?(claims, params) do
    case params["MediaSourceId"] || params["mediaSourceId"] do
      nil -> true
      id -> id == claims.media_source_id
    end
  end

  # Static=true (default for DirectPlay URLs) serves the original file.
  # Static=false is remux/transcode progressive — not implemented yet.
  defp static_request?(params) do
    case params["Static"] || params["static"] do
      v when v in [false, "false", "False", "0", 0] -> false
      _ -> true
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
