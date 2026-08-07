defmodule HivefinWeb.Compat.Tier02EndpointsTest do
  @moduledoc """
  Compatibility tests: Hivefin HTTP responses must satisfy Jellyfin 10.9.x
  shape contracts (required keys + types) from fixture packs.

  Fixtures under test/support/fixtures/jellyfin/{web,androidtv}/.
  Android TV fixtures are hand-authored until a live capture is available.
  """

  use HivefinWeb.ConnCase, async: true

  alias Hivefin.JellyfinShape
  alias Hivefin.Library.LibraryContext
  alias Hivefin.Scanner

  @movies_path Path.expand("test/support/fixtures/media_tree/movies", File.cwd!())

  setup %{conn: conn} do
    {:ok, user} =
      Hivefin.Accounts.create_user(%{
        name: "Compat User",
        username: "compat",
        password: "password1",
        admin: true
      })

    {:ok, token, _} =
      Hivefin.Accounts.issue_token(user, %{
        device_id: "compat-device",
        device_name: "Compat",
        client: "Jellyfin Web",
        client_version: "10.9.11"
      })

    auth_conn =
      conn
      |> put_req_header(
        "x-emby-authorization",
        ~s(MediaBrowser Client="Jellyfin Web", Device="Compat", DeviceId="compat-device", Version="10.9.11", Token="#{token}")
      )

    {:ok, library} =
      LibraryContext.create_library(%{
        name: "Movies",
        type: :movies,
        path: @movies_path
      })

    assert :ok = Scanner.scan_library_sync(library.id)
    [movie] = LibraryContext.list_items(library.id, type: :movie)

    {:ok,
     conn: auth_conn, raw_conn: conn, user: user, library: library, movie: movie, token: token}
  end

  for client <- ["web", "androidtv"] do
    describe "shape contracts (#{client})" do
      test "POST /Users/AuthenticateByName matches authenticate_by_name fixture", %{
        raw_conn: conn
      } do
        client = unquote(client)

        expected =
          JellyfinShape.load_fixture(client, "authenticate_by_name")
          |> JellyfinShape.shape_from_sample()

        conn =
          conn
          |> put_req_header(
            "x-emby-authorization",
            ~s(MediaBrowser Client="Jellyfin Web", Device="Chrome", DeviceId="web-1", Version="10.9.11")
          )
          |> put_req_header("content-type", "application/json")
          |> post(~p"/Users/AuthenticateByName", %{Username: "compat", Pw: "password1"})

        body = json_response(conn, 200)
        JellyfinShape.assert_shape(body, expected)
        refute Map.has_key?(body, "Path")
      end

      test "GET /System/Info/Public matches system_info_public fixture", %{raw_conn: conn} do
        client = unquote(client)

        expected =
          JellyfinShape.load_fixture(client, "system_info_public")
          |> JellyfinShape.shape_from_sample()

        body =
          conn
          |> get(~p"/System/Info/Public")
          |> json_response(200)

        JellyfinShape.assert_shape(body, expected)
        # Discovery identity must match Jellyfin Server for @jellyfin/sdk scoring
        assert body["ProductName"] == "Jellyfin Server"
      end

      test "GET /System/Info matches system_info fixture", %{conn: conn} do
        client = unquote(client)

        expected =
          JellyfinShape.load_fixture(client, "system_info")
          |> JellyfinShape.shape_from_sample()

        body =
          conn
          |> get(~p"/System/Info")
          |> json_response(200)

        JellyfinShape.assert_shape(body, expected)
        assert body["ProductName"] == "Jellyfin Server"
      end

      test "GET /Users/:id/Views matches views fixture", %{conn: conn, user: user} do
        client = unquote(client)

        expected =
          JellyfinShape.load_fixture(client, "views")
          |> JellyfinShape.shape_from_sample()

        body =
          conn
          |> get(~p"/Users/#{user.id}/Views")
          |> json_response(200)

        JellyfinShape.assert_shape(body, expected)
        assert is_list(body["Items"])
        refute Enum.any?(body["Items"], &Map.has_key?(&1, "Path"))
      end

      test "GET /Users/:id/Items matches items_list fixture", %{
        conn: conn,
        user: user,
        library: library
      } do
        client = unquote(client)

        expected =
          JellyfinShape.load_fixture(client, "items_list")
          |> JellyfinShape.shape_from_sample()

        body =
          conn
          |> get(~p"/Users/#{user.id}/Items", %{
            "ParentId" => library.id,
            "IncludeItemTypes" => "Movie"
          })
          |> json_response(200)

        JellyfinShape.assert_shape(body, expected)
        refute Enum.any?(body["Items"], &Map.has_key?(&1, "Path"))
      end

      test "POST /Items/:id/PlaybackInfo matches playback_info fixture", %{
        conn: conn,
        movie: movie
      } do
        client = unquote(client)

        expected =
          JellyfinShape.load_fixture(client, "playback_info")
          |> JellyfinShape.shape_from_sample()

        body = %{
          "DeviceProfile" => %{
            "DirectPlayProfiles" => [
              %{
                "Container" => "mp4",
                "Type" => "Video",
                "VideoCodec" => "h264",
                "AudioCodec" => "aac"
              }
            ]
          }
        }

        response =
          conn
          |> post(~p"/Items/#{movie.id}/PlaybackInfo", body)
          |> json_response(200)

        JellyfinShape.assert_shape(response, expected)
        [source | _] = response["MediaSources"]
        refute Map.has_key?(source, "Path")
        assert is_binary(source["DirectStreamUrl"])
      end
    end
  end
end
