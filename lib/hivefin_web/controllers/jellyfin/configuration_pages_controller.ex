defmodule HivefinWeb.Jellyfin.ConfigurationPagesController do
  @moduledoc """
  No plugins are installed, so there are no plugin-contributed configuration
  pages. The dashboard `.map`s this response directly, so it must be a bare
  JSON array, not the SPA HTML fallback.
  """
  use HivefinWeb, :controller

  @doc """
  `GET /web/ConfigurationPages` — bare array of ConfigurationPageInfo.
  """
  def index(conn, _params) do
    json(conn, [])
  end
end
