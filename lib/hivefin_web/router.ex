defmodule HivefinWeb.Router do
  use HivefinWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :jellyfin_api do
    plug :accepts, ["json"]
  end

  # Progressive/HLS streams: clients send Accept: video/*, */*, or no Accept.
  # Do not negotiate JSON-only — binary send_file / m3u8 responses.
  pipeline :jellyfin_stream do
  end

  pipeline :jellyfin_auth do
    plug HivefinWeb.Plugs.JellyfinAuth
  end

  scope "/", HivefinWeb do
    get "/healthz", HealthController, :show
  end

  # Stream routes — token via query param; not limited to application/json Accept.
  scope "/", HivefinWeb.Jellyfin do
    pipe_through :jellyfin_stream

    get "/Videos/:item_id/stream", VideoController, :stream
    get "/Videos/:item_id/stream.:container", VideoController, :stream
    get "/Videos/:item_id/master.m3u8", VideoController, :master_m3u8
  end

  scope "/", HivefinWeb.Jellyfin do
    pipe_through :jellyfin_api

    get "/System/Info/Public", SystemController, :public_info
    post "/Users/AuthenticateByName", UserController, :authenticate_by_name

    pipe_through :jellyfin_auth
    get "/System/Info", SystemController, :info
    get "/Users/Me", UserController, :me
    get "/Users/:user_id/Views", ItemsController, :views
    get "/Users/:user_id/Items", ItemsController, :index
    get "/Users/:user_id/Items/:item_id", ItemsController, :show
    get "/Shows/:series_id/Seasons", ItemsController, :seasons
    get "/Shows/:series_id/Episodes", ItemsController, :episodes
    get "/Items/:item_id/Images/:image_type", ImagesController, :show
    post "/Items/:item_id/PlaybackInfo", PlaybackController, :create
  end

  scope "/api", HivefinWeb do
    pipe_through :api
  end
end
