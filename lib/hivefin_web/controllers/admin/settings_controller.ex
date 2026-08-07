defmodule HivefinWeb.Admin.SettingsController do
  use HivefinWeb, :controller

  alias Hivefin.Settings

  def index(conn, _params) do
    render(conn, :index,
      page_title: "Settings",
      active: :settings,
      current_user: conn.assigns.current_admin,
      settings: Settings.admin_snapshot()
    )
  end

  def update(conn, %{"settings" => params}) do
    errors =
      []
      |> maybe_put_server_name(params)
      |> maybe_put_tmdb_key(params)
      |> maybe_put_rate_limit(params)

    case errors do
      [] ->
        conn
        |> put_flash(:info, "Settings saved.")
        |> redirect(to: ~p"/admin/settings")

      msgs ->
        conn
        |> put_flash(:error, Enum.join(msgs, "; "))
        |> redirect(to: ~p"/admin/settings")
    end
  end

  def update(conn, _params) do
    conn
    |> put_flash(:error, "Nothing to update.")
    |> redirect(to: ~p"/admin/settings")
  end

  def clear_tmdb_key(conn, _params) do
    :ok = Settings.delete("tmdb_api_key")

    conn
    |> put_flash(:info, "Cleared stored TMDB API key (env HIVEFIN_TMDB_API_KEY still applies if set).")
    |> redirect(to: ~p"/admin/settings")
  end

  defp maybe_put_server_name(errors, params) do
    case params["server_name"] do
      name when is_binary(name) and name != "" ->
        case Settings.put("server_name", String.trim(name)) do
          {:ok, _} -> errors
          {:error, _} -> ["Could not save server name" | errors]
        end

      _ ->
        errors
    end
  end

  defp maybe_put_tmdb_key(errors, params) do
    key = params["tmdb_api_key"]

    if is_binary(key) and String.trim(key) != "" do
      case Settings.put("tmdb_api_key", String.trim(key)) do
        {:ok, _} -> errors
        {:error, _} -> ["Could not save TMDB API key" | errors]
      end
    else
      # Leave blank = keep existing
      errors
    end
  end

  defp maybe_put_rate_limit(errors, params) do
    case params["tmdb_rate_limit_per_sec"] do
      raw when is_binary(raw) and raw != "" ->
        case Integer.parse(raw) do
          {n, _} when n > 0 and n <= 100 ->
            case Settings.put("tmdb_rate_limit_per_sec", n) do
              {:ok, _} -> errors
              {:error, _} -> ["Could not save rate limit" | errors]
            end

          _ ->
            ["Rate limit must be an integer 1–100" | errors]
        end

      _ ->
        errors
    end
  end
end
