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
            stream_format: stream_format_for_conn(conn),
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

  # jellyfin-web (incl. official Android WebView) plays progressive MP4 natively.
  # jellyfin-vue always feeds non-DirectPlay into hls.js and needs HLS.
  defp stream_format_for_conn(conn) do
    header =
      case get_req_header(conn, "x-emby-authorization") do
        [h | _] -> h
        [] -> List.first(get_req_header(conn, "authorization")) || ""
      end

    client =
      case Regex.run(~r/Client="([^"]*)"/i, header || "") do
        [_, c] -> String.downcase(c)
        _ -> ""
      end

    cond do
      String.contains?(client, "vue") -> :hls
      String.contains?(client, "jellyfin web") -> :progressive
      String.contains?(client, "android") -> :progressive
      true -> :hls
    end
  end
end
