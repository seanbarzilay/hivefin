defmodule HivefinWeb.Jellyfin.ScheduledTasksController do
  @moduledoc """
  No scheduled tasks are implemented; the dashboard's task list must still get
  a JSON array, not the SPA HTML fallback (it `.map`s the response directly).
  """
  use HivefinWeb, :controller

  @doc """
  `GET /ScheduledTasks` — bare array of TaskInfo. jellyfin-web sends an
  `IsEnabled` query param in the wild; ignore all query params.
  """
  def index(conn, _params) do
    json(conn, [])
  end
end
