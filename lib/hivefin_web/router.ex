defmodule HivefinWeb.Router do
  use HivefinWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {HivefinWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

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

  pipeline :admin_auth do
    plug HivefinWeb.Plugs.AdminAuth
  end

  scope "/", HivefinWeb do
    get "/healthz", HealthController, :show
    get "/readyz", ReadyController, :show
  end

  # Minimal operator console (session cookie; admin users only)
  scope "/admin", HivefinWeb.Admin do
    pipe_through :browser

    get "/login", SessionController, :new
    post "/login", SessionController, :create
    delete "/logout", SessionController, :delete

    pipe_through :admin_auth

    get "/", DashboardController, :index

    get "/libraries", LibraryController, :index
    post "/libraries", LibraryController, :create
    post "/libraries/scan-all", LibraryController, :scan_all
    get "/libraries/:id/edit", LibraryController, :edit
    put "/libraries/:id", LibraryController, :update
    post "/libraries/:id/scan", LibraryController, :scan
    post "/libraries/:id/cancel-scan", LibraryController, :cancel_scan
    delete "/libraries/:id", LibraryController, :delete

    get "/users", UserController, :index
    post "/users", UserController, :create
    post "/users/:id/password", UserController, :reset_password
    delete "/users/:id", UserController, :delete

    get "/settings", SettingsController, :index
    post "/settings", SettingsController, :update
    delete "/settings/tmdb-key", SettingsController, :clear_tmdb_key
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
    get "/System/Ping", SystemController, :ping
    post "/System/Ping", SystemController, :ping
    get "/Branding/Configuration", BrandingController, :configuration
    get "/Users/Public", UserController, :public_users
    post "/Users/AuthenticateByName", UserController, :authenticate_by_name


    pipe_through :jellyfin_auth
    get "/System/Info", SystemController, :info
    get "/Users/Me", UserController, :me

    get "/Users/:user_id/Views", ItemsController, :views
    # Modern SDK paths used by jellyfin-vue (fetchIndexPage + item/library pages)
    get "/UserViews", ItemsController, :user_views
    get "/Items/Latest", ItemsController, :latest
    get "/UserItems/Resume", ItemsController, :user_items_resume
    # GET /Items before /Items/:id so list is not captured as show
    get "/Items", ItemsController, :index
    get "/Items/:item_id/Similar", ItemsController, :similar
    get "/Items/:item_id/Images/:image_type", ImagesController, :show
    post "/Items/:item_id/PlaybackInfo", PlaybackController, :create
    get "/Items/:item_id", ItemsController, :show

    # Resume before Items/:item_id so "Resume" is not captured as an id
    get "/Users/:user_id/Items/Resume", ItemsController, :resume
    get "/Users/:user_id/Items", ItemsController, :index
    get "/Users/:user_id/Items/:item_id", ItemsController, :show
    post "/Users/:user_id/Items/:item_id/UserData", SessionsController, :update_user_data
    post "/Users/:user_id/PlayedItems/:item_id", SessionsController, :mark_played
    # NextUp before Shows/:series_id/* so "NextUp" is not a series id
    get "/Shows/NextUp", ItemsController, :next_up
    get "/Shows/:series_id/Seasons", ItemsController, :seasons
    get "/Shows/:series_id/Episodes", ItemsController, :episodes

    get "/DisplayPreferences/:display_preferences_id", DisplayPreferencesController, :show
    post "/DisplayPreferences/:display_preferences_id", DisplayPreferencesController, :update
    get "/Sessions", SessionsController, :index
    post "/Sessions/Capabilities", SessionsController, :capabilities
    post "/Sessions/Capabilities/Full", SessionsController, :capabilities_full
    post "/Sessions/Playing", SessionsController, :playing
    post "/Sessions/Playing/Progress", SessionsController, :progress
    post "/Sessions/Playing/Stopped", SessionsController, :stopped
  end


  scope "/api", HivefinWeb do
    pipe_through :api
  end
end
