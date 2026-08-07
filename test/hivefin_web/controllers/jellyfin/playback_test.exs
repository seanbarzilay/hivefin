defmodule HivefinWeb.Jellyfin.PlaybackTest do
  use HivefinWeb.ConnCase, async: true

  alias Hivefin.Jellyfin.Id

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
    assert media_source["Id"] == Id.format(source.id)
    assert media_source["Container"] == "mp4"
    assert media_source["SupportsDirectPlay"] == true
    assert media_source["SupportsDirectStream"] == true
    refute Map.has_key?(media_source, "Path")
    assert is_binary(media_source["DirectStreamUrl"])
    assert media_source["DirectStreamUrl"] =~ "/Videos/#{Id.format(source.id)}/stream"
    assert media_source["DirectStreamUrl"] =~ "api_key="
    assert media_source["DirectStreamUrl"] =~ "MediaSourceId=#{Id.format(source.id)}"
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

  test "GET stream with mediaSourceId path and access token (jellyfin-vue)", %{
    source: source,
    user: user
  } do
    {:ok, access_token, _} =
      Hivefin.Accounts.issue_token(user, %{
        device_id: "vue-stream",
        device_name: "Chrome",
        client: "Vue",
        client_version: "1"
      })

    expected_size = File.stat!(@fixture_mp4).size

    conn =
      build_conn()
      |> get(~p"/Videos/#{source.id}/stream.mp4", %{
        "Static" => "true",
        "mediaSourceId" => source.id,
        "api_key" => access_token
      })

    assert conn.status == 200
    body = response(conn, 200)
    assert byte_size(body) == expected_size
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

  @tag :ffmpeg
  test "remux Static=false streams progressive fMP4", %{
    movie: movie,
    source: source,
    user: user
  } do
    token = StreamToken.sign(user.id, movie.id, source.id)
    session = "play-remux-#{System.unique_integer([:positive])}"

    conn =
      build_conn()
      |> get(~p"/Videos/#{movie.id}/stream.mp4", %{
        "MediaSourceId" => source.id,
        "api_key" => token,
        "Static" => "false",
        "PlaySessionId" => session
      })

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") |> List.first() =~ "video/mp4"
    body = response(conn, 200)
    assert byte_size(body) > 0
  end

  @tag :ffmpeg
  test "transcode progressive stream.mp4 streams re-encoded fMP4", %{
    movie: movie,
    source: source,
    user: user
  } do
    token = StreamToken.sign(user.id, movie.id, source.id)
    session = "play-xcode-#{System.unique_integer([:positive])}"

    conn =
      build_conn()
      |> get(~p"/Videos/#{movie.id}/stream.mp4", %{
        "MediaSourceId" => source.id,
        "api_key" => token,
        "PlaySessionId" => session,
        "Static" => "false",
        "Transcode" => "true",
        "MaxHeight" => "240"
      })

    assert conn.status == 200
    body = response(conn, 200)
    assert byte_size(body) > 100
    refute body =~ "ffmpeg"
  end

  @tag :ffmpeg
  test "transcode returns 503 when at capacity", %{
    movie: movie,
    source: source,
    user: user
  } do
    previous = Application.get_env(:hivefin, :max_transcodes)
    Application.put_env(:hivefin, :max_transcodes, 1)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:hivefin, :max_transcodes, previous),
        else: Application.delete_env(:hivefin, :max_transcodes)
    end)

    token = StreamToken.sign(user.id, movie.id, source.id)

    # Hold capacity with a direct session
    assert {:ok, hold} =
             Hivefin.Playback.Supervisor.start_session(%{
               id: "hold-#{System.unique_integer([:positive])}",
               mode: :remux,
               input_path: @fixture_mp4
             })

    conn =
      build_conn()
      |> get(~p"/Videos/#{movie.id}/stream.mp4", %{
        "MediaSourceId" => source.id,
        "api_key" => token,
        "Static" => "false",
        "Transcode" => "true",
        "PlaySessionId" => "busy-#{System.unique_integer([:positive])}"
      })

    assert %{"error" => "too_many_transcodes"} = json_response(conn, 503)

    Hivefin.Playback.Session.stop(hold)
  end

  test "PlaybackInfo transcode uses progressive fMP4 so vue uses video.src", %{
    conn: conn,
    movie: movie
  } do
    body = %{
      "DeviceProfile" => %{
        "DirectPlayProfiles" => [
          %{
            "Container" => "mp4",
            "Type" => "Video",
            "VideoCodec" => "hevc",
            "AudioCodec" => "aac"
          }
        ]
      }
    }

    conn = post(conn, ~p"/Items/#{movie.id}/PlaybackInfo", body)
    assert %{"MediaSources" => [ms]} = json_response(conn, 200)
    assert ms["SupportsTranscoding"] == true
    # SupportsDirectPlay true forces jellyfin-vue onto video.src (not live hls.js).
    assert ms["SupportsDirectPlay"] == true
    assert ms["SupportsDirectStream"] == false
    assert ms["TranscodingSubProtocol"] == "http"
    assert ms["TranscodingContainer"] == "mp4"
    assert ms["TranscodingUrl"] =~ "stream.mp4"
    assert ms["TranscodingUrl"] =~ "Transcode=true"
    assert ms["TranscodingUrl"] =~ "Static=false"
  end

  test "PlaybackInfo remux uses progressive fMP4 without Static DirectStream", %{
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
    assert ms["Id"] == Id.format(source.id)
    assert ms["SupportsDirectPlay"] == true
    # Must be false: vue builds Static=true stream.Container when true
    assert ms["SupportsDirectStream"] == false
    assert is_binary(ms["TranscodingUrl"])
    assert ms["TranscodingUrl"] =~ "stream.mp4"
    assert ms["TranscodingSubProtocol"] == "http"
    assert ms["TranscodingContainer"] == "mp4"
    refute ms["TranscodingUrl"] =~ "Transcode=true"
    assert ms["TranscodingUrl"] =~ "Static=false"
    refute Map.has_key?(ms, "Path")
  end
end
