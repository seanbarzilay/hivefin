defmodule HivefinWeb.Jellyfin.PlaybackTest do
  use HivefinWeb.ConnCase, async: true

  alias Hivefin.Library.LibraryContext
  alias Hivefin.Playback.StreamToken
  alias Hivefin.Scanner

  @movies_path Path.expand("test/support/fixtures/media_tree/movies", File.cwd!())
  @fixture_mp4 Path.expand(
                 "test/support/fixtures/media_tree/movies/Big Buck Bunny (2008)/Big Buck Bunny (2008).mp4",
                 File.cwd!()
               )

  setup %{conn: conn} do
    {:ok, user} =
      Hivefin.Accounts.create_user(%{
        name: "Playback",
        username: "playback",
        password: "password1",
        admin: true
      })

    {:ok, token, _} =
      Hivefin.Accounts.issue_token(user, %{
        device_id: "dev",
        device_name: "Dev",
        client: "Test",
        client_version: "1.0"
      })

    conn =
      conn
      |> put_req_header(
        "x-emby-authorization",
        ~s(MediaBrowser Client="Test", Device="Dev", DeviceId="dev", Version="1.0", Token="#{token}")
      )

    {:ok, library} =
      LibraryContext.create_library(%{
        name: "Movies",
        type: :movies,
        path: @movies_path
      })

    assert :ok = Scanner.scan_library_sync(library.id)

    [movie] = LibraryContext.list_items(library.id, type: :movie)
    [source] = LibraryContext.list_media_sources(movie.id)

    {:ok, conn: conn, user: user, library: library, movie: movie, source: source}
  end

  test "POST PlaybackInfo returns MediaSources without Path and with DirectStreamUrl", %{
    conn: conn,
    movie: movie,
    source: source,
    user: user
  } do
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

    conn = post(conn, ~p"/Items/#{movie.id}/PlaybackInfo", body)

    assert %{
             "MediaSources" => [media_source],
             "PlaySessionId" => session_id
           } = json_response(conn, 200)

    assert is_binary(session_id)
    assert media_source["Id"] == source.id
    assert media_source["Container"] == "mp4"
    assert media_source["SupportsDirectPlay"] == true
    assert media_source["SupportsDirectStream"] == true
    refute Map.has_key?(media_source, "Path")
    assert is_binary(media_source["DirectStreamUrl"])
    assert media_source["DirectStreamUrl"] =~ "/Videos/#{movie.id}/stream"
    assert media_source["DirectStreamUrl"] =~ "api_key="
    assert media_source["DirectStreamUrl"] =~ "MediaSourceId=#{source.id}"
    assert media_source["MediaStreams"] != []

    # Token in URL is valid for this user/item/source
    token =
      media_source["DirectStreamUrl"]
      |> URI.parse()
      |> Map.fetch!(:query)
      |> URI.decode_query()
      |> Map.fetch!("api_key")

    assert {:ok, claims} = StreamToken.verify(token)
    assert claims.user_id == user.id
    assert claims.item_id == movie.id
    assert claims.media_source_id == source.id
  end

  test "POST PlaybackInfo is unauthorized without token", %{movie: movie} do
    conn = build_conn()
    conn = post(conn, ~p"/Items/#{movie.id}/PlaybackInfo", %{})
    assert json_response(conn, 401)
  end

  test "GET stream serves fixture mp4 with stream token", %{
    movie: movie,
    source: source,
    user: user
  } do
    token = StreamToken.sign(user.id, movie.id, source.id)
    expected_size = File.stat!(@fixture_mp4).size

    conn =
      build_conn()
      |> get(~p"/Videos/#{movie.id}/stream", %{
        "MediaSourceId" => source.id,
        "api_key" => token,
        "Static" => "true"
      })

    assert conn.status == 200
    assert get_resp_header(conn, "accept-ranges") == ["bytes"]
    assert get_resp_header(conn, "content-type") == ["video/mp4"]
    body = response(conn, 200)
    assert byte_size(body) == expected_size
    # ftyp box — mp4 signature
    assert binary_part(body, 4, 4) == "ftyp"
  end

  test "GET stream accepts video/* Accept header (not JSON-only pipeline)", %{
    movie: movie,
    source: source,
    user: user
  } do
    token = StreamToken.sign(user.id, movie.id, source.id)

    conn =
      build_conn()
      |> put_req_header("accept", "video/mp4, video/*, */*")
      |> get(~p"/Videos/#{movie.id}/stream", %{
        "MediaSourceId" => source.id,
        "api_key" => token
      })

    # Would be 406 if stuck behind accepts: ["json"] only
    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["video/mp4"]
  end

  test "GET stream supports Range requests", %{movie: movie, source: source, user: user} do
    token = StreamToken.sign(user.id, movie.id, source.id)
    expected_size = File.stat!(@fixture_mp4).size

    conn =
      build_conn()
      |> put_req_header("range", "bytes=0-99")
      |> get(~p"/Videos/#{movie.id}/stream", %{
        "MediaSourceId" => source.id,
        "api_key" => token
      })

    assert conn.status == 206
    assert get_resp_header(conn, "content-range") == ["bytes 0-99/#{expected_size}"]
    body = response(conn, 206)
    assert byte_size(body) == 100
  end

  test "GET stream rejects missing token", %{movie: movie, source: source} do
    conn =
      build_conn()
      |> get(~p"/Videos/#{movie.id}/stream", %{"MediaSourceId" => source.id})

    assert json_response(conn, 401)
  end

  test "GET stream rejects token for wrong item", %{
    movie: movie,
    source: source,
    user: user
  } do
    other_item = Ecto.UUID.generate()
    token = StreamToken.sign(user.id, other_item, source.id)

    conn =
      build_conn()
      |> get(~p"/Videos/#{movie.id}/stream", %{
        "MediaSourceId" => source.id,
        "api_key" => token
      })

    assert json_response(conn, 403)
  end

  test "remux Static=false returns 501 until Task 8", %{
    movie: movie,
    source: source,
    user: user
  } do
    token = StreamToken.sign(user.id, movie.id, source.id)

    conn =
      build_conn()
      |> get(~p"/Videos/#{movie.id}/stream.ts", %{
        "MediaSourceId" => source.id,
        "api_key" => token,
        "Static" => "false"
      })

    assert %{"error" => "remux_not_implemented"} = json_response(conn, 501)
  end

  test "transcode master.m3u8 returns 501 with valid token", %{
    movie: movie,
    source: source,
    user: user
  } do
    token = StreamToken.sign(user.id, movie.id, source.id)

    conn =
      build_conn()
      |> get(~p"/Videos/#{movie.id}/master.m3u8", %{
        "MediaSourceId" => source.id,
        "api_key" => token
      })

    assert %{"error" => "transcode_not_implemented"} = json_response(conn, 501)
  end

  test "PlaybackInfo mkv profile yields DirectStream remux URL", %{
    conn: conn,
    movie: movie,
    source: source
  } do
    # Force remux decision by only allowing a non-mp4 container in DirectPlay
    body = %{
      "DeviceProfile" => %{
        "DirectPlayProfiles" => [
          %{
            "Container" => "mkv",
            "Type" => "Video",
            "VideoCodec" => "h264",
            "AudioCodec" => "aac"
          }
        ]
      }
    }

    # Source is mp4 — codecs ok, container not in direct play → remux
    conn = post(conn, ~p"/Items/#{movie.id}/PlaybackInfo", body)
    assert %{"MediaSources" => [ms]} = json_response(conn, 200)
    assert ms["Id"] == source.id
    assert ms["SupportsDirectPlay"] == false
    assert ms["SupportsDirectStream"] == true
    assert is_binary(ms["TranscodingUrl"])
    assert ms["TranscodingUrl"] =~ "stream.ts"
    assert ms["TranscodingContainer"] == "ts"
    refute Map.has_key?(ms, "Path")
  end
end
