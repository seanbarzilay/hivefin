defmodule HivefinWeb.Router do
  use HivefinWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", HivefinWeb do
    get "/healthz", HealthController, :show
  end

  scope "/api", HivefinWeb do
    pipe_through :api
  end
end
