defmodule HivefinWeb.Jellyfin.PlaybackController do
  use HivefinWeb, :controller

  alias Hivefin.Jellyfin.Dto.PlaybackInfo
  alias Hivefin.Library.LibraryContext
  alias Hivefin.Playback.DeviceProfile

  # Cap BitrateTest payload so a misbehaving client cannot request huge blobs.
  @bitrate_test_max_bytes 3_000_000

  @doc """
  `POST /Items/:item_id/PlaybackInfo` — returns MediaSources with stream URLs.
  """
  def create(conn, %{"item_id" => item_id} = params) do
    body = params_body(params)

    case LibraryContext.get_item_with_sources(item_id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{"error" => "not_found"})

      item ->
        profile = DeviceProfile.from_playback_info_body(body)

        response =
          PlaybackInfo.build(item, conn.assigns.current_user,
            device_profile: profile,
            browser_safe: browser_safe_client?(conn),
            base_url: request_base_url(conn),
            play_session_id:
              params["PlaySessionId"] ||
                body["PlaySessionId"] ||
                get_in(body, ["playbackInfoDto", "PlaySessionId"])
          )

        json(conn, response)
    end
  end

  @doc """
  `GET /Playback/BitrateTest` — jellyfin-web probes this before play to size
  the adaptive bitrate. Returns a fixed-size binary (zeros).
  """
  def bitrate_test(conn, params) do
    size =
      case Integer.parse(to_string(params["Size"] || params["size"] || "500000")) do
        {n, _} when n > 0 -> min(n, @bitrate_test_max_bytes)
        _ -> 500_000
      end

    conn
    |> put_resp_content_type("application/octet-stream", nil)
    |> put_resp_header("cache-control", "no-cache, no-store")
    |> send_resp(200, :binary.copy(<<0>>, size))
  end

  # Phoenix merges JSON body into params; strip route keys for profile parse.
  defp params_body(params) do
    Map.drop(params, ["item_id", "id"])
  end

  # Only jellyfin-web (HTML5 / hls.js) needs browser_html5 DirectPlay rules.
  # Official Android app Client is "Jellyfin for Android" and uses ExoPlayer with
  # its own DeviceProfile (MKV/HEVC DirectPlay + HLS/TS transcode) — see
  # jellyfin-android DeviceProfileBuilder + QueueManager.createVideoMediaSource.
  defp browser_safe_client?(conn) do
    client = client_name(conn)

    cond do
      client == "" -> false
      String.contains?(client, "vue") -> false
      # Native mobile / TV players
      String.contains?(client, "android") -> false
      String.contains?(client, "androidtv") -> false
      String.contains?(client, "fire tv") -> false
      String.contains?(client, "roku") -> false
      String.contains?(client, "kodi") -> false
      String.contains?(client, "infuse") -> false
      String.contains?(client, "swiftfin") -> false
      # Desktop / embedded jellyfin-web
      String.contains?(client, "web") -> true
      String.contains?(client, "chrome") -> true
      String.contains?(client, "firefox") -> true
      String.contains?(client, "safari") -> true
      String.contains?(client, "edge") -> true
      true -> false
    end
  end

  defp client_name(conn) do
    header =
      case get_req_header(conn, "x-emby-authorization") do
        [h | _] -> h
        [] -> List.first(get_req_header(conn, "authorization")) || ""
      end

    case Regex.run(~r/Client="([^"]*)"/i, header || "") do
      [_, c] -> String.downcase(c)
      _ -> ""
    end
  end

  defp request_base_url(conn) do
    # Prefer the Host the client used; fall back to configured LAN address when
    # the request arrives as loopback (docker health checks / local curl).
    host = conn.host

    if host in ["127.0.0.1", "localhost", "0.0.0.0", "::1"] do
      case Application.get_env(:hivefin, :local_address) do
        url when is_binary(url) and url != "" ->
          url |> String.trim() |> String.trim_trailing("/")

        _ ->
          build_base_url(conn.scheme, host, conn.port)
      end
    else
      build_base_url(conn.scheme, host, conn.port)
    end
  end

  defp build_base_url(scheme, host, port) do
    scheme = to_string(scheme)

    default_port? =
      (scheme == "http" and port == 80) or (scheme == "https" and port == 443)

    if default_port? do
      "#{scheme}://#{host}"
    else
      "#{scheme}://#{host}:#{port}"
    end
  end
end
