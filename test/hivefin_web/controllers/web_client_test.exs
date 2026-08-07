defmodule HivefinWeb.WebClientTest do
  @moduledoc """
  The bundled jellyfin-web client must be reachable at both `/` (official
  Android/TV WebViews load the server root) and `/web` (Jellyfin's canonical
  location, which the LG webOS app requires).
  """
  # async: false — stages files in the app's priv dir.
  use HivefinWeb.ConnCase, async: false

  @web_dir Application.compile_env(:hivefin, :jellyfin_web_dir) ||
             Application.app_dir(:hivefin, "priv/jellyfin-web")

  @manifest ~s({"start_url":"index.html#/home.html","name":"Jellyfin"})
  @index "<html><body>jellyfin-web</body></html>"

  setup do
    File.mkdir_p!(@web_dir)

    # Only create what is missing, and only remove what we created, so a real
    # bundled build is never clobbered.
    created =
      for {name, body} <- [{"index.html", @index}, {"manifest.json", @manifest}],
          path = Path.join(@web_dir, name),
          not File.exists?(path) do
        File.write!(path, body)
        path
      end

    on_exit(fn -> Enum.each(created, &File.rm/1) end)
    :ok
  end

  describe "LG webOS bootstrap sequence (frontend/js/index.js)" do
    test "GET /web/manifest.json returns the manifest, not a JSON 404", %{conn: conn} do
      conn = get(conn, "/web/manifest.json")

      assert conn.status == 200
      body = response(conn, 200)
      assert {:ok, %{"start_url" => start_url}} = Jason.decode(body)
      # The app branches on whether start_url already contains "/web".
      assert is_binary(start_url)
    end

    test "GET /web/index.html serves the client", %{conn: conn} do
      conn = get(conn, "/web/index.html")
      assert conn.status == 200
      assert response(conn, 200) =~ "jellyfin-web"
    end

    test "GET /web/ falls back to index.html for SPA routing", %{conn: conn} do
      conn = get(conn, "/web/")
      assert conn.status == 200
      assert response(conn, 200) =~ "jellyfin-web"
    end
  end

  test "GET / still serves the client (Android/TV WebView root)", %{conn: conn} do
    conn = get(conn, "/")
    assert conn.status == 200
    assert response(conn, 200) =~ "jellyfin-web"
  end

  test "missing asset under /web 404s instead of returning index.html", %{conn: conn} do
    # Returning HTML here breaks jellyfin-web's dynamic imports.
    conn = get(conn, "/web/main.deadbeef.chunk.js")
    assert conn.status == 404
    refute response(conn, 404) =~ "jellyfin-web"
  end

  test "unrouted API paths still 404 as JSON, not SPA HTML" do
    for path <- ["/System/NoSuchThing", "/Items/NoSuchThing/Bogus", "/socket"] do
      conn = get(build_conn(), path)
      assert conn.status in [401, 404], "#{path} → #{conn.status}"

      if conn.status == 404 do
        assert {:ok, %{"error" => _}} = Jason.decode(response(conn, 404)),
               "#{path} should 404 as JSON"
      end
    end
  end
end
