defmodule HivefinWeb.Admin.AdminConsoleTest do
  use HivefinWeb.ConnCase, async: true

  alias Hivefin.Accounts
  alias Hivefin.Library.LibraryContext

  @movies_path Path.expand("test/support/fixtures/media_tree/movies", File.cwd!())

  setup do
    {:ok, admin} =
      Accounts.create_user(%{
        name: "Admin",
        username: "adminui",
        password: "password1",
        admin: true
      })

    {:ok, user} =
      Accounts.create_user(%{
        name: "Viewer",
        username: "viewer",
        password: "password1",
        admin: false
      })

    %{admin: admin, user: user}
  end

  test "login page renders", %{conn: conn} do
    conn = get(conn, ~p"/admin/login")
    assert html_response(conn, 200) =~ "Hivefin"
    assert html_response(conn, 200) =~ "Sign in"
  end

  test "dashboard requires auth", %{conn: conn} do
    conn = get(conn, ~p"/admin")
    assert redirected_to(conn) == ~p"/admin/login"
  end

  test "non-admin cannot log into admin console", %{conn: conn, user: user} do
    conn =
      post(conn, ~p"/admin/login", %{
        "username" => user.username,
        "password" => "password1"
      })

    assert redirected_to(conn) == ~p"/admin/login"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "not an administrator"
  end

  test "admin can log in and open dashboard", %{conn: conn, admin: admin} do
    conn =
      post(conn, ~p"/admin/login", %{
        "username" => admin.username,
        "password" => "password1"
      })

    assert redirected_to(conn) == ~p"/admin"

    conn = get(conn, ~p"/admin")
    assert html_response(conn, 200) =~ "Dashboard"
    assert html_response(conn, 200) =~ admin.username
  end

  test "admin can create a library", %{conn: conn, admin: admin} do
    conn = log_in_admin(conn, admin)

    conn =
      post(conn, ~p"/admin/libraries", %{
        "library" => %{
          "name" => "Movies",
          "type" => "movies",
          "path" => @movies_path
        }
      })

    assert redirected_to(conn) == ~p"/admin/libraries"
    assert [%{name: "Movies"}] = LibraryContext.list_libraries()
  end

  test "admin can create a user and reset password", %{conn: conn, admin: admin} do
    conn = log_in_admin(conn, admin)

    conn =
      post(conn, ~p"/admin/users", %{
        "user" => %{
          "username" => "newbie",
          "name" => "New User",
          "password" => "password1",
          "admin" => "false"
        }
      })

    assert redirected_to(conn) == ~p"/admin/users"
    user = Enum.find(Accounts.list_users(), &(&1.username == "newbie"))
    assert user
    refute user.admin

    conn =
      post(conn, ~p"/admin/users/#{user.id}/password", %{
        "password" => "password2"
      })

    assert redirected_to(conn) == ~p"/admin/users"
    assert {:ok, _} = Accounts.authenticate("newbie", "password2")
  end

  test "admin can edit library name and path", %{conn: conn, admin: admin} do
    conn = log_in_admin(conn, admin)

    {:ok, library} =
      LibraryContext.create_library(%{
        name: "Movies",
        type: :movies,
        path: @movies_path
      })

    conn =
      put(conn, ~p"/admin/libraries/#{library.id}", %{
        "library" => %{"name" => "Films", "path" => @movies_path}
      })

    assert redirected_to(conn) == ~p"/admin/libraries"
    assert LibraryContext.get_library(library.id).name == "Films"
  end

  test "admin settings page and save server name", %{conn: conn, admin: admin} do
    conn = log_in_admin(conn, admin)

    conn = get(conn, ~p"/admin/settings")
    assert html_response(conn, 200) =~ "TMDB"

    conn =
      post(conn, ~p"/admin/settings", %{
        "settings" => %{
          "server_name" => "HivefinTest",
          "tmdb_rate_limit_per_sec" => "5",
          "tmdb_api_key" => ""
        }
      })

    assert redirected_to(conn) == ~p"/admin/settings"
    assert Application.get_env(:hivefin, :server_name) == "HivefinTest"
    assert Hivefin.Settings.get("server_name") == "HivefinTest"
  end

  test "libraries page shows rescan all", %{conn: conn, admin: admin} do
    conn = log_in_admin(conn, admin)
    conn = get(conn, ~p"/admin/libraries")
    assert html_response(conn, 200) =~ "Rescan all"
  end

  defp log_in_admin(conn, admin) do
    conn
    |> post(~p"/admin/login", %{
      "username" => admin.username,
      "password" => "password1"
    })
    |> recycle()
  end
end
