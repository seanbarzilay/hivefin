defmodule HivefinWeb.ReadyControllerTest do
  use HivefinWeb.ConnCase

  alias Hivefin.Library.LibraryContext

  test "GET /readyz is 200 when Repo and ffmpeg/ffprobe are available", %{conn: conn} do
    conn = get(conn, ~p"/readyz")
    assert %{"status" => "ready", "checks" => checks} = json_response(conn, 200)
    assert checks["database"] == true
    assert checks["ffmpeg"] == true
    assert checks["ffprobe"] == true
  end

  test "GET /readyz stays ready when a library root is missing (degraded)", %{conn: conn} do
    missing =
      Path.join(System.tmp_dir!(), "hivefin-missing-root-#{System.unique_integer([:positive])}")

    # Bypass create_library path validation by inserting via context after creating a real dir then removing it
    tmp = Path.join(System.tmp_dir!(), "hivefin-readyz-lib-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    {:ok, library} =
      LibraryContext.create_library(%{
        name: "Missing Root Lib",
        type: :movies,
        path: tmp
      })

    File.rm_rf!(tmp)
    refute File.dir?(library.path)
    # ensure path is gone (may equal missing if we renamed — we just deleted tmp)
    _ = missing

    conn = get(conn, ~p"/readyz")
    assert %{"status" => "ready"} = json_response(conn, 200)
  end

  test "GET /readyz is 503 when ffmpeg path is missing", %{conn: conn} do
    previous = Application.get_env(:hivefin, :ffmpeg_path)

    Application.put_env(
      :hivefin,
      :ffmpeg_path,
      "/nonexistent/hivefin-ffmpeg-#{System.unique_integer([:positive])}"
    )

    try do
      conn = get(conn, ~p"/readyz")
      assert %{"status" => "not_ready", "checks" => checks} = json_response(conn, 503)
      assert checks["ffmpeg"] == false
      assert checks["database"] == true
    after
      if previous do
        Application.put_env(:hivefin, :ffmpeg_path, previous)
      else
        Application.delete_env(:hivefin, :ffmpeg_path)
      end
    end
  end
end
