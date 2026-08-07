defmodule HivefinWeb.Jellyfin.BrandingController do
  use HivefinWeb, :controller

  @doc """
  Branding options (unauthenticated). Jellyfin Vue fetches this after discovery.
  """
  def configuration(conn, _params) do
    json(conn, branding_options())
  end

  defp branding_options do
    %{
      "LoginDisclaimer" => "",
      "CustomCss" => "",
      "SplashscreenEnabled" => false
    }
  end
end
