defmodule HivefinWeb.Jellyfin.BrandingController do
  use HivefinWeb, :controller

  @doc """
  Branding options (unauthenticated). Jellyfin clients fetch this after discovery.
  """
  def configuration(conn, _params) do
    json(conn, branding_options())
  end

  @doc """
  Custom CSS endpoint. Official web UI requests `/Branding/Css` (empty is fine).
  """
  def css(conn, _params) do
    conn
    |> put_resp_content_type("text/css")
    |> send_resp(200, branding_options()["CustomCss"] || "")
  end

  defp branding_options do
    %{
      "LoginDisclaimer" => "",
      "CustomCss" => "",
      "SplashscreenEnabled" => false
    }
  end
end

