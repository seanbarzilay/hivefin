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
        profile =
          body
          |> DeviceProfile.from_playback_info_body()

        # Also accept top-level DeviceProfile already in params
        profile =
          if Map.has_key?(params, "DeviceProfile") do
            DeviceProfile.from_jellyfin(params["DeviceProfile"])
          else
            profile
          end

        response =
          PlaybackInfo.build(item, conn.assigns.current_user,
            device_profile: profile,
            play_session_id: params["PlaySessionId"] || body["PlaySessionId"]
          )

        json(conn, response)
    end
  end

  # Phoenix merges JSON body into params; strip route keys for profile parse.
  defp params_body(params) do
    Map.drop(params, ["item_id", "id"])
  end
end
