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
        client: "Jellyfin Vue",
        client_version: "1.0"
      })

    # Client name selects stream format (Vue → HLS; Jellyfin Web → progressive).
    conn =
      conn
      |> put_req_header(
        "x-emby-authorization",
        ~s(MediaBrowser Client="Jellyfin Vue", Device="Dev", DeviceId="dev", Version="1.0", Token="#{token}")
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

  test "POST PlaybackInfo returns MediaSources with DirectStreamUrl", %{
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
    # Jellyfin primary MediaSource.Id == Item.Id
    assert media_source["Id"] == Id.format(movie.id)
    assert media_source["ItemId"] == Id.format(movie.id)
    assert media_source["Container"] == "mp4"
    assert media_source["SupportsDirectPlay"] == true
    assert media_source["SupportsDirectStream"] == true
    # HTTP Path is the playable stream URL (not a filesystem path)
    assert is_binary(media_source["Path"])
    assert media_source["Path"] =~ "/Videos/"
    assert is_binary(media_source["DirectStreamUrl"])
    assert media_source["DirectStreamUrl"] =~ "/Videos/#{Id.format(movie.id)}/stream"
    assert media_source["DirectStreamUrl"] =~ "api_key="
    assert media_source["DirectStreamUrl"] =~ "MediaSourceId=#{Id.format(movie.id)}"
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

  # jellyfin-android's ResolvingDataSource injects `Authorization: MediaBrowser
  # ... Token="..."` on every ExoPlayer request and deliberately keeps the token
  # out of the URL, so a stream request carries no api_key at all. Rejecting it
  # made ExoPlayer retry forever: empty player at 00:00.
  for {label, header_name} <- [
        {"MediaBrowser Authorization header", "authorization"},
        {"X-Emby-Authorization header", "x-emby-authorization"}
      ] do
    test "GET stream authorizes via #{label} (no api_key in URL)", %{
      movie: movie,
      user: user
    } do
      {:ok, token, _} =
        Hivefin.Accounts.issue_token(user, %{
          device_id: "pixel",
          device_name: "Pixel",
          client: "Jellyfin for Android",
          client_version: "2.6.3"
        })

      conn =
        build_conn()
        |> put_req_header(
          unquote(header_name),
          ~s(MediaBrowser Client="Jellyfin for Android", Device="Pixel", DeviceId="pixel", Version="2.6.3", Token="#{token}")
        )
        |> get(~p"/Videos/#{movie.id}/stream", %{"Static" => "true"})

      assert conn.status == 200
      assert byte_size(response(conn, 200)) == File.stat!(@fixture_mp4).size
    end
  end

  test "GET stream authorizes via X-Emby-Token header", %{movie: movie, user: user} do
    {:ok, token, _} =
      Hivefin.Accounts.issue_token(user, %{
        device_id: "tv",
        device_name: "TV",
        client: "Android TV",
        client_version: "0.17.0"
      })

    conn =
      build_conn()
      |> put_req_header("x-emby-token", token)
      |> get(~p"/Videos/#{movie.id}/stream", %{"Static" => "true"})

    assert conn.status == 200
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

  @tag :ffmpeg
  test "GET master.m3u8 (Transcode=true) serves a VOD playlist sized to ceil(runtime/segment), every listed segment fetches 200",
       %{user: user} do
    # Big Buck Bunny (2008).mp4 (the shared setup fixture) is 1.000000s, so
    # ceil(1/4) == 1 regardless of whether the segment-count formula is
    # right — degenerate. A 12s source makes ceil(12/4) == 3 discriminating,
    # and Transcode=true exercises the mode where segments are actually
    # pinned to hls_segment_seconds/0 by -force_key_frames (remux is a
    # stream copy with no keyframe control — see build_hls_result/5 in
    # VideoController — and intentionally never gets the VOD treatment).
    tmp_root =
      Path.join(System.tmp_dir!(), "hivefin-hls-vod-#{System.unique_integer([:positive])}")

    movie_dir = Path.join(tmp_root, "Synth Clip (2024)")
    fixture = Path.join(movie_dir, "Synth Clip (2024).mp4")
    File.mkdir_p!(movie_dir)
    on_exit(fn -> File.rm_rf(tmp_root) end)

    {_, 0} =
      System.cmd(
        "ffmpeg",
        ~w(-y -hide_banner -loglevel error -f lavfi -i testsrc=duration=12:size=320x240:rate=24
           -f lavfi -i sine=duration=12
           -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest) ++ [fixture]
      )

    {:ok, library} =
      LibraryContext.create_library(%{name: "SynthMovies", type: :movies, path: tmp_root})

    assert :ok = Scanner.scan_library_sync(library.id)
    [movie] = LibraryContext.list_items(library.id, type: :movie)
    [source] = LibraryContext.list_media_sources(movie.id)

    token = StreamToken.sign(user.id, movie.id, source.id)
    session = "play-hls-vod-#{System.unique_integer([:positive])}"

    conn =
      build_conn()
      |> get(~p"/Videos/#{movie.id}/master.m3u8", %{
        "MediaSourceId" => source.id,
        "api_key" => token,
        "PlaySessionId" => session,
        "Transcode" => "true"
      })

    assert conn.status == 200

    assert get_resp_header(conn, "content-type") |> List.first() =~
             "application/vnd.apple.mpegurl"

    playlist = response(conn, 200)
    refute playlist == ""
    assert playlist =~ "#EXT-X-PLAYLIST-TYPE:VOD"
    assert playlist =~ "#EXT-X-ENDLIST"
    refute playlist =~ "EVENT"

    segment_lines =
      playlist
      |> String.split("\n")
      |> Enum.filter(&String.starts_with?(&1, "hls/"))

    # Non-vacuous, and the actual discriminating assertion: a wrong
    # segment-count formula (or the VOD builder wrongly applied where
    # ffmpeg doesn't actually cut segments at hls_segment_seconds/0) would
    # fail this, unlike against the 1s fixture where ceil(1/4) == 1 no
    # matter what.
    assert segment_lines != []
    assert length(segment_lines) == ceil(12 / Hivefin.Playback.FFmpeg.Args.hls_segment_seconds())

    [hls_session_id | _] =
      segment_lines |> hd() |> String.trim_leading("hls/") |> String.split("/")

    on_exit(fn -> Hivefin.Playback.Session.stop(hls_session_id) end)

    # Every segment the playlist lists must actually be fetchable — this is
    # what would have caught the VOD-for-remux bug: a playlist advertising
    # segments ffmpeg never writes 404s here instead of passing silently.
    for segment_line <- segment_lines do
      "hls/" <> session_and_query = segment_line
      [session_path, query] = String.split(session_and_query, "?", parts: 2)

      seg_conn =
        build_conn()
        |> get("/Videos/#{movie.id}/hls/#{session_path}?#{query}")

      assert seg_conn.status == 200
      assert byte_size(response(seg_conn, 200)) > 0
    end
  end

  test "PlaybackInfo respects nested playbackInfoDto.DeviceProfile (SDK shape)", %{
    conn: conn,
    movie: movie
  } do
    # Restrictive profile nested under playbackInfoDto — must NOT fall back to
    # default (which DirectPlays mkv) or the fixture mp4 would DirectPlay wrongly
    # when the client only allows hevc (forcing transcode).
    body = %{
      "playbackInfoDto" => %{
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
    }

    conn = post(conn, ~p"/Items/#{movie.id}/PlaybackInfo", body)
    assert %{"MediaSources" => [ms]} = json_response(conn, 200)
    # Fixture is h264/aac/mp4 — hevc-only DirectPlay profile forces transcode
    assert ms["SupportsDirectPlay"] == false
    assert ms["SupportsTranscoding"] == true
    assert ms["TranscodingSubProtocol"] == "hls"
    assert ms["TranscodingUrl"] =~ "master.m3u8"
  end

  test "PlaybackInfo DirectPlays when profile allows container and codecs", %{
    conn: conn,
    movie: movie
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
    assert %{"MediaSources" => [ms]} = json_response(conn, 200)
    assert ms["SupportsDirectPlay"] == true
    assert ms["SupportsDirectStream"] == true
    assert is_binary(ms["DirectStreamUrl"])
    assert ms["DirectStreamUrl"] =~ "Static=true"
    assert ms["Id"] == Id.format(movie.id)
  end

  test "PlaybackInfo remuxes via HLS when container not allowed", %{
    conn: conn,
    movie: movie,
    source: _source
  } do
    # Force remux: codecs ok, only mkv allowed as DirectPlay (fixture is mp4)
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

    conn = post(conn, ~p"/Items/#{movie.id}/PlaybackInfo", body)
    assert %{"MediaSources" => [ms]} = json_response(conn, 200)
    assert ms["Id"] == Id.format(movie.id)
    assert ms["SupportsDirectPlay"] == false
    # Must be false: vue builds Static=true stream.Container when true
    assert ms["SupportsDirectStream"] == false
    assert ms["SupportsTranscoding"] == true
    assert is_binary(ms["TranscodingUrl"])
    # jellyfin-vue requires HLS for non-DirectPlay (always uses hls.js)
    assert ms["TranscodingSubProtocol"] == "hls"
    assert ms["TranscodingContainer"] == "ts"
    # Container stays the SOURCE container — this fixture is mp4. Reporting "ts"
    # made jellyfin-web treat the stream as MPEG-TS and use the native <video>
    # element, which Chrome cannot demux (DEMUXER_ERROR_COULD_NOT_PARSE), so
    # hls.js was never engaged.
    assert ms["Container"] == "mp4"
    assert ms["Protocol"] == "File"
    assert ms["DefaultAudioStreamIndex"] == 1
    refute Map.get(ms, "StreamUrl")
    assert Enum.any?(ms["MediaStreams"], &(&1["Codec"] == "h264" and &1["Type"] == "Video"))
    assert Enum.any?(ms["MediaStreams"], &(&1["Codec"] == "aac" and &1["Type"] == "Audio"))
    assert ms["TranscodingUrl"] =~ "master.m3u8"
    assert ms["TranscodingUrl"] =~ "Static=false"
    refute ms["TranscodingUrl"] =~ "Transcode=true"
  end

  test "PlaybackInfo transcodes via HLS when video codec not allowed", %{
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
    assert ms["SupportsDirectPlay"] == false
    assert ms["SupportsDirectStream"] == false
    assert ms["SupportsTranscoding"] == true
    assert ms["TranscodingSubProtocol"] == "hls"
    assert ms["TranscodingContainer"] == "ts"
    assert ms["TranscodingUrl"] =~ "master.m3u8"
    assert ms["TranscodingUrl"] =~ "Transcode=true"
  end

  test "GET /Playback/BitrateTest returns octet-stream body", %{conn: conn} do
    conn = get(conn, ~p"/Playback/BitrateTest?Size=1024")
    assert response(conn, 200)
    assert get_resp_header(conn, "content-type") |> hd() =~ "octet-stream"
    assert byte_size(response(conn, 200)) == 1024
  end

  test "Jellyfin Web (browser_safe) forces HLS transcode without StreamUrl", %{
    movie: movie,
    source: source,
    user: user
  } do
    # Make the source browser-unsafe (mkv/hevc) so browser_html5 forces transcode.
    {:ok, source} =
      source
      |> Ecto.Changeset.change(%{container: "mkv"})
      |> Hivefin.Repo.update()

    source = Hivefin.Repo.preload(source, :media_streams, force: true)

    for stream <- source.media_streams do
      codec = if stream.type == :video, do: "hevc", else: stream.codec || "ac3"

      stream
      |> Ecto.Changeset.change(%{codec: codec})
      |> Hivefin.Repo.update()
    end

    {:ok, token, _} =
      Hivefin.Accounts.issue_token(user, %{
        device_id: "web-1",
        device_name: "Chrome",
        client: "Jellyfin Web",
        client_version: "10.9.0"
      })

    conn =
      build_conn()
      |> put_req_header(
        "x-emby-authorization",
        ~s(MediaBrowser Client="Jellyfin Web", Device="Android", DeviceId="web-1", Version="10.9.0", Token="#{token}")
      )

    conn = post(conn, ~p"/Items/#{movie.id}/PlaybackInfo", %{})
    assert %{"MediaSources" => [ms]} = json_response(conn, 200)
    assert ms["SupportsDirectPlay"] == false
    assert ms["SupportsTranscoding"] == true
    assert ms["TranscodingSubProtocol"] == "hls"
    assert ms["TranscodingContainer"] == "ts"
    # Container stays the SOURCE container. Reporting "ts" made jellyfin-web treat
    # the stream as MPEG-TS and use the native <video> element, which Chrome cannot
    # demux (DEMUXER_ERROR_COULD_NOT_PARSE) so hls.js was never engaged.
    assert ms["Container"] == "mkv"
    assert ms["TranscodingUrl"] =~ "master.m3u8"
    assert ms["TranscodingUrl"] =~ "Transcode=true"
    # StreamUrl must be absent — jellyfin-web short-circuits on it.
    refute Map.has_key?(ms, "StreamUrl")
    assert ms["RunTimeTicks"]
    assert Enum.any?(ms["MediaStreams"], &(&1["Codec"] == "h264"))
  end

  test "Jellyfin for Android honors ExoPlayer DeviceProfile (DirectPlay MKV/HEVC)", %{
    movie: movie,
    source: source,
    user: user
  } do
    # Source looks like 102 Dalmatians: mkv + hevc
    {:ok, source} =
      source
      |> Ecto.Changeset.change(%{container: "mkv"})
      |> Hivefin.Repo.update()

    source = Hivefin.Repo.preload(source, :media_streams, force: true)

    for stream <- source.media_streams do
      codec = if stream.type == :video, do: "hevc", else: stream.codec || "ac3"

      stream
      |> Ecto.Changeset.change(%{codec: codec})
      |> Hivefin.Repo.update()
    end

    {:ok, token, _} =
      Hivefin.Accounts.issue_token(user, %{
        device_id: "pixel",
        device_name: "Pixel",
        client: "Jellyfin for Android",
        client_version: "2.6.3"
      })

    conn =
      build_conn()
      |> put_req_header(
        "x-emby-authorization",
        ~s(MediaBrowser Client="Jellyfin for Android", Device="Pixel", DeviceId="pixel", Version="2.6.3", Token="#{token}")
      )

    # Same shape as DeviceProfileBuilder transcoding + DirectPlay MKV/HEVC
    body = %{
      "DeviceProfile" => %{
        "DirectPlayProfiles" => [
          %{
            "Container" => "mkv",
            "Type" => "Video",
            "VideoCodec" => "h264,hevc,mpeg4,vp9",
            "AudioCodec" => "aac,mp3,ac3,eac3,flac,dts"
          }
        ],
        "TranscodingProfiles" => [
          %{
            "Container" => "ts",
            "Type" => "Video",
            "VideoCodec" => "h264",
            "AudioCodec" => "aac,mp3,ac3",
            "Protocol" => "hls",
            "Context" => "Streaming"
          }
        ]
      }
    }

    conn = post(conn, ~p"/Items/#{movie.id}/PlaybackInfo", body)
    assert %{"MediaSources" => [ms]} = json_response(conn, 200)
    # Must DirectPlay — not force HTML5 browser_safe transcode
    assert ms["SupportsDirectPlay"] == true
    assert ms["Protocol"] == "File"
    assert is_binary(ms["DirectStreamUrl"])
    assert ms["DirectStreamUrl"] =~ "Static=true"
    refute ms["TranscodingUrl"]
  end

  # Properties jellyfin-sdk-kotlin declares with NO default value, so
  # kotlinx.serialization requires the key to be present. A missing one raises
  # MissingFieldException: the Android app drops the MediaSource and never
  # requests a stream (empty player, 00:00). jellyfin-web is JS and tolerates
  # absence — that is why the browser played while the app hung.
  # Listed literally (not read from SdkRequired) so shrinking that list fails here.
  # Source: jellyfin-model/.../api/{MediaSourceInfo,MediaStream}.kt
  @sdk_required_source ~w(
    Protocol Type IsRemote ReadAtNativeFramerate IgnoreDts IgnoreIndex GenPtsInput
    SupportsTranscoding SupportsDirectStream SupportsDirectPlay IsInfiniteStream
    RequiresOpening RequiresClosing RequiresLooping SupportsProbing
    TranscodingSubProtocol HasSegments
  )

  @sdk_required_stream ~w(
    IsInterlaced IsDefault IsForced IsHearingImpaired IsOriginal Type Index
    IsExternal IsTextSubtitleStream SupportsExternalStream
  )

  for {label, client} <- [
        {"DirectPlay (Android/ExoPlayer)", "Jellyfin for Android"},
        {"HLS transcode (browser_safe)", "Jellyfin Web"}
      ] do
    test "MediaSource carries every Kotlin-SDK-required field — #{label}", %{
      movie: movie,
      source: source,
      user: user
    } do
      # mkv/hevc: DirectPlay for the ExoPlayer profile, forced HLS transcode for web.
      {:ok, source} =
        source |> Ecto.Changeset.change(%{container: "mkv"}) |> Hivefin.Repo.update()

      source = Hivefin.Repo.preload(source, :media_streams, force: true)

      for stream <- source.media_streams do
        codec = if stream.type == :video, do: "hevc", else: stream.codec || "ac3"
        stream |> Ecto.Changeset.change(%{codec: codec}) |> Hivefin.Repo.update()
      end

      {:ok, token, _} =
        Hivefin.Accounts.issue_token(user, %{
          device_id: "dev-1",
          device_name: "Device",
          client: unquote(client),
          client_version: "1.0.0"
        })

      body =
        if unquote(client) == "Jellyfin for Android" do
          %{
            "DeviceProfile" => %{
              "DirectPlayProfiles" => [
                %{"Container" => "mkv", "Type" => "Video", "VideoCodec" => "hevc"}
              ]
            }
          }
        else
          %{}
        end

      conn =
        build_conn()
        |> put_req_header(
          "x-emby-authorization",
          ~s(MediaBrowser Client="#{unquote(client)}", Device="Device", DeviceId="dev-1", Version="1.0.0", Token="#{token}")
        )
        |> post(~p"/Items/#{movie.id}/PlaybackInfo", body)

      assert %{"MediaSources" => [ms]} = json_response(conn, 200)

      for key <- @sdk_required_source do
        assert Map.has_key?(ms, key), "MediaSourceInfo missing required key #{key}"
        refute is_nil(ms[key]), "MediaSourceInfo required key #{key} is null"
      end

      # TranscodingSubProtocol is a non-null enum: only "http" or "hls".
      assert ms["TranscodingSubProtocol"] in ["http", "hls"]

      assert ms["MediaStreams"] != []

      for stream <- ms["MediaStreams"], key <- @sdk_required_stream do
        assert Map.has_key?(stream, key), "MediaStream #{stream["Index"]} missing #{key}"
        refute is_nil(stream[key]), "MediaStream #{stream["Index"]} key #{key} is null"
      end
    end
  end
end
