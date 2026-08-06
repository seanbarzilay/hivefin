defmodule HivefinWeb.ReadyController do
  @moduledoc """
  Readiness probe: Postgres + ffmpeg/ffprobe must be available.

  Missing library media roots are degraded (logged warning) but still ready
  so the API can run for setup.
  """

  use HivefinWeb, :controller

  require Logger

  alias Hivefin.Library.LibraryContext
  alias Hivefin.Repo

  def show(conn, _params) do
    checks = %{
      database: database_ok?(),
      ffmpeg: executable_ok?(:ffmpeg_path, "ffmpeg"),
      ffprobe: executable_ok?(:ffprobe_path, "ffprobe")
    }

    warn_missing_media_roots()

    if checks.database and checks.ffmpeg and checks.ffprobe do
      conn
      |> put_status(:ok)
      |> json(%{status: "ready", checks: checks})
    else
      conn
      |> put_status(:service_unavailable)
      |> json(%{status: "not_ready", checks: checks})
    end
  end

  defp database_ok? do
    case Repo.query("SELECT 1") do
      {:ok, _} -> true
      {:error, _} -> false
    end
  rescue
    _ -> false
  end

  defp executable_ok?(config_key, default_name) do
    configured = Application.get_env(:hivefin, config_key)

    path =
      cond do
        is_binary(configured) and configured != "" and String.contains?(configured, "/") ->
          configured

        is_binary(configured) and configured != "" ->
          System.find_executable(configured) || configured

        true ->
          System.find_executable(default_name)
      end

    is_binary(path) and path != "" and
      ((String.contains?(path, "/") and File.regular?(path)) or
         is_binary(System.find_executable(path)))
  end

  defp warn_missing_media_roots do
    libraries =
      try do
        LibraryContext.list_libraries()
      rescue
        _ -> []
      end

    Enum.each(libraries, fn lib ->
      path = lib.path

      if is_binary(path) and path != "" and not File.dir?(path) do
        Logger.warning(
          "readiness degraded: library #{lib.id} (#{lib.name}) media root missing: #{path}"
        )
      end
    end)
  end
end
