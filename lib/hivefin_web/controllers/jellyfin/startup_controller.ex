defmodule HivefinWeb.Jellyfin.StartupController do
  @moduledoc """
  Startup wizard stubs. Wizard is already completed; clients still probe these
  during web UI bootstrap.
  """
  use HivefinWeb, :controller

  alias Hivefin.Jellyfin.SystemInfo

  @doc """
  `GET /Startup/Configuration` — public bootstrap config.
  """
  def configuration(conn, _params) do
    json(conn, %{
      "ServerName" => SystemInfo.server_name(),
      "UICulture" => "en-US",
      "MetadataCountryCode" => "US",
      "PreferredMetadataLanguage" => "en"
    })
  end
end
