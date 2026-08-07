defmodule HivefinWeb.Jellyfin.PlaybackController do
  use HivefinWeb, :controller

  alias Hivefin.Jellyfin.Dto.PlaybackInfo
  alias Hivefin.Library.LibraryContext
  alias Hivefin.Playback.DeviceProfile

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

  # Phoenix merges JSON body into params; strip route keys for profile parse.
  defp params_body(params) do
    Map.drop(params, ["item_id", "id"])
  end

  # jellyfin-web / Android WebView use HTML5 (+ hls.js). Ignore ExoPlayer MKV profiles.
  # jellyfin-vue keeps the client DeviceProfile as-is.
  defp browser_safe_client?(conn) do
    client = client_name(conn)
    not String.contains?(client, "vue")
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
