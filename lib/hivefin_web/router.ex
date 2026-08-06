defmodule HivefinWeb.Router do
  use HivefinWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :jellyfin_api do
    plug :accepts, ["json"]
  end

  pipeline :jellyfin_auth do
    plug HivefinWeb.Plugs.JellyfinAuth
  end

  scope "/", HivefinWeb do
    get "/healthz", HealthController, :show
  end

  scope "/", HivefinWeb.Jellyfin do
    pipe_through :jellyfin_api

    get "/System/Info/Public", SystemController, :public_info
    post "/Users/AuthenticateByName", UserController, :authenticate_by_name

    pipe_through :jellyfin_auth
    get "/System/Info", SystemController, :info
    get "/Users/Me", UserController, :me
  end

  scope "/api", HivefinWeb do
    pipe_through :api
  end
end
