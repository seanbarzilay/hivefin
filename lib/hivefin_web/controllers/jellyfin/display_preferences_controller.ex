defmodule HivefinWeb.Jellyfin.DisplayPreferencesController do
  @moduledoc """
  Jellyfin DisplayPreferences stubs.

  Android TV and Web clients fetch display preferences at startup. Returning
  404 breaks the shell; defaults with empty CustomPrefs are enough for v1.
  """

  use HivefinWeb, :controller

  @doc """
  `GET /DisplayPreferences/:display_preferences_id`
  """
  def show(conn, params) do
    id = params["display_preferences_id"] || params["id"] || "usersettings"
    client = params["client"] || params["Client"] || "emby"
    user_id = params["userId"] || params["UserId"]

    json(conn, default_prefs(id, client, user_id))
  end

  @doc """
  `POST /DisplayPreferences/:display_preferences_id` — accept and ignore.
  """
  def update(conn, _params) do
    conn
    |> put_status(:no_content)
    |> send_resp(:no_content, "")
  end

  defp default_prefs(id, client, user_id) do
    %{
      "Id" => id,
      "UserId" => user_id,
      "Client" => client,
      "SortBy" => "SortName",
      "SortOrder" => "Ascending",
      "RememberIndexing" => false,
      "RememberSorting" => false,
      "PrimaryImageHeight" => 250,
      "PrimaryImageWidth" => 250,
      "ScrollDirection" => "Horizontal",
      "ShowBackdrop" => true,
      "ShowSidebar" => false,
      "CustomPrefs" => %{}
    }
  end
end
