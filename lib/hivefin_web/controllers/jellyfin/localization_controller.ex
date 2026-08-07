defmodule HivefinWeb.Jellyfin.LocalizationController do
  @moduledoc """
  Localization stubs for jellyfin-web bootstrap.

  Without these the SPA receives index.html (200) for API paths and hangs on
  the loading spinner.
  """
  use HivefinWeb, :controller

  @doc """
  `GET /Localization/Cultures` — minimal culture list.
  """
  def cultures(conn, _params) do
    json(conn, [
      %{
        "DisplayName" => "English",
        "Name" => "English",
        "ThreeLetterISOLanguageName" => "eng",
        "TwoLetterISOLanguageName" => "en",
        "ThreeLetterISOLanguageNames" => ["eng"],
        "TwoLetterISOLanguageNames" => ["en"]
      }
    ])
  end

  @doc """
  `GET /Localization/Options` — UI language options.
  """
  def options(conn, _params) do
    json(conn, [
      %{
        "Name" => "English",
        "Value" => "en-US"
      }
    ])
  end

  @doc """
  `GET /Localization/Countries` — empty list is fine.
  """
  def countries(conn, _params) do
    json(conn, [])
  end

  @doc """
  `GET /Localization/ParentalRatings` — empty list is fine.
  """
  def parental_ratings(conn, _params) do
    json(conn, [])
  end
end
