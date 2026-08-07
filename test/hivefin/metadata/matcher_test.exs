defmodule Hivefin.Metadata.MatcherTest do
  use Hivefin.DataCase, async: false

  alias Hivefin.Library.{Item, LibraryContext}
  alias Hivefin.Metadata.{ImageCache, Matcher, TMDB, Worker}

  setup do
    Req.Test.verify_on_exit!()

    tmp =
      Path.join(System.tmp_dir!(), "hivefin-meta-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp)
    previous_dir = Application.get_env(:hivefin, :image_cache_dir)
    previous_req = Application.get_env(:hivefin, :metadata_req_options)

    Application.put_env(:hivefin, :image_cache_dir, tmp)

    Application.put_env(:hivefin, :metadata_req_options,
      plug: {Req.Test, TMDB},
      retry: false
    )

    on_exit(fn ->
      Application.put_env(:hivefin, :image_cache_dir, previous_dir)
      Application.put_env(:hivefin, :metadata_req_options, previous_req)
      File.rm_rf(tmp)
    end)

    {:ok, library} =
      LibraryContext.create_library(%{
        name: "Movies",
        type: :movies,
        path: Path.expand("test/support/fixtures/media_tree/movies", File.cwd!())
      })

    {:ok, item, :created} =
      LibraryContext.find_or_create_movie(library.id, %{
        name: "Inception",
        production_year: 2010
      })

    %{item: item, library: library, cache_dir: tmp}
  end

  test "match_movie finds TMDB hit by name/year", %{item: item} do
    stub_tmdb_search_and_details()

    assert {:ok, match} = Matcher.match_movie(item)
    assert match.tmdb_id == 27205
    assert match.name == "Inception"
    assert match.overview =~ "dream"
    assert match.provider_ids["Tmdb"] == "27205"
    assert match.poster_path == "/poster.jpg"
  end

  test "match_movie returns no_match when search empty", %{item: item} do
    Req.Test.stub(TMDB, fn conn ->
      assert String.ends_with?(conn.request_path, "/search/movie")
      assert conn.query_params["api_key"]
      assert conn.query_params["query"] == "Inception"
      Req.Test.json(conn, %{"results" => []})
    end)

    assert {:error, :no_match} = Matcher.match_movie(item)
  end

  test "match_movie rejects score-0 results (unrelated name/year)", %{item: item} do
    Req.Test.stub(TMDB, fn conn ->
      assert String.ends_with?(conn.request_path, "/search/movie")

      Req.Test.json(conn, %{
        "results" => [
          %{
            "id" => 1,
            "title" => "Completely Different Film",
            "overview" => "no affinity",
            "release_date" => "1999-01-01",
            "poster_path" => "/z.jpg",
            "backdrop_path" => nil
          }
        ]
      })
    end)

    assert {:error, :no_match} = Matcher.match_movie(item)
  end

  test "match_movie accepts fuzzy token overlap with year", %{library: library} do
    {:ok, item, :created} =
      LibraryContext.find_or_create_movie(library.id, %{
        name: "Inception Movie",
        production_year: 2010
      })

    Req.Test.stub(TMDB, fn conn ->
      path = conn.request_path || ""

      cond do
        String.ends_with?(path, "/search/movie") ->
          Req.Test.json(conn, %{
            "results" => [
              %{
                "id" => 27205,
                "title" => "Inception",
                "overview" => "dreams",
                "release_date" => "2010-07-16",
                "poster_path" => "/p.jpg",
                "backdrop_path" => nil
              }
            ]
          })

        String.contains?(path, "/movie/27205") ->
          Req.Test.json(conn, %{
            "id" => 27205,
            "title" => "Inception",
            "overview" => "dreams",
            "release_date" => "2010-07-16",
            "poster_path" => "/p.jpg",
            "backdrop_path" => nil
          })

        true ->
          conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{})
      end
    end)

    assert {:ok, match} = Matcher.match_movie(item)
    assert match.tmdb_id == 27205
  end

  test "match_movie retries without year when year filter is empty", %{item: item} do
    Req.Test.stub(TMDB, fn conn ->
      path = conn.request_path || ""

      cond do
        String.ends_with?(path, "/search/movie") and Map.has_key?(conn.query_params, "year") ->
          Req.Test.json(conn, %{"results" => []})

        String.ends_with?(path, "/search/movie") ->
          Req.Test.json(conn, %{
            "results" => [
              %{
                "id" => 27205,
                "title" => "Inception",
                "overview" => "dreams",
                "release_date" => "2010-07-16",
                "poster_path" => "/p.jpg",
                "backdrop_path" => nil
              }
            ]
          })

        String.contains?(path, "/movie/27205") ->
          Req.Test.json(conn, %{
            "id" => 27205,
            "title" => "Inception",
            "overview" => "dreams",
            "release_date" => "2010-07-16",
            "poster_path" => "/p.jpg",
            "backdrop_path" => nil
          })

        true ->
          conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{})
      end
    end)

    assert {:ok, match} = Matcher.match_movie(item)
    assert match.tmdb_id == 27205
  end

  test "match_movie prefers existing provider id", %{item: item} do
    {:ok, item} =
      item
      |> Item.changeset(%{provider_ids: %{"Tmdb" => "99"}})
      |> Repo.update()

    Req.Test.stub(TMDB, fn conn ->
      assert String.ends_with?(conn.request_path, "/movie/99")

      Req.Test.json(conn, %{
        "id" => 99,
        "title" => "Existing",
        "overview" => "from details",
        "release_date" => "2010-07-16",
        "poster_path" => "/x.jpg",
        "backdrop_path" => "/y.jpg"
      })
    end)

    assert {:ok, match} = Matcher.match_movie(item)
    assert match.tmdb_id == 99
    assert match.name == "Existing"
  end

  test "Worker.refresh_item updates overview and stores images", %{item: item, cache_dir: dir} do
    stub_tmdb_full_pipeline()

    assert :ok = Worker.refresh_item(item.id)

    refreshed = LibraryContext.get_item(item.id)
    assert is_binary(refreshed.overview)
    assert refreshed.overview =~ "dream"
    assert refreshed.provider_ids["Tmdb"] == "27205"

    primary = Path.join([dir, item.id, "primary.jpg"])
    assert File.regular?(primary)

    tags = ImageCache.image_tags_for(refreshed)
    assert Map.has_key?(tags, "Primary")
  end

  test "Worker.refresh_item is best-effort on provider failure", %{item: item} do
    Req.Test.stub(TMDB, fn conn ->
      conn
      |> Plug.Conn.put_status(500)
      |> Req.Test.json(%{"status_message" => "boom"})
    end)

    assert :ok = Worker.refresh_item(item.id)
  end

  defp stub_tmdb_search_and_details do
    Req.Test.stub(TMDB, fn conn ->
      path = conn.request_path || ""

      cond do
        String.ends_with?(path, "/search/movie") ->
          Req.Test.json(conn, %{
            "results" => [
              %{
                "id" => 27205,
                "title" => "Inception",
                "overview" => "A thief who steals corporate secrets through dream-sharing.",
                "release_date" => "2010-07-16",
                "poster_path" => "/poster.jpg",
                "backdrop_path" => "/back.jpg"
              }
            ]
          })

        String.contains?(path, "/movie/27205") ->
          Req.Test.json(conn, %{
            "id" => 27205,
            "title" => "Inception",
            "overview" => "A thief who steals corporate secrets through dream-sharing.",
            "release_date" => "2010-07-16",
            "poster_path" => "/poster.jpg",
            "backdrop_path" => "/back.jpg"
          })

        true ->
          conn
          |> Plug.Conn.put_status(404)
          |> Req.Test.json(%{})
      end
    end)
  end

  defp stub_tmdb_full_pipeline do
    jpeg =
      Base.decode64!(
        "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/2wBDAQkJCQwLDBgNDRgyIRwhMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjL/wAARCAABAAEDASIAAhEBAxEB/8QAFQABAQAAAAAAAAAAAAAAAAAAAAn/xAAUEAEAAAAAAAAAAAAAAAAAAAAA/8QAFQEBAQAAAAAAAAAAAAAAAAAAAAX/xAAUEQEAAAAAAAAAAAAAAAAAAAAA/9oADAMBAAIQAxAAAAGcP//EABQQAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQEAAQUCf//EABQRAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQMBAT8Bf//EABQRAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQIBAT8Bf//EABQQAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQEABj8Cf//EABQQAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQEAAT8hf//Z"
      )

    Req.Test.stub(TMDB, fn conn ->
      path = conn.request_path || ""

      cond do
        String.ends_with?(path, "/search/movie") ->
          Req.Test.json(conn, %{
            "results" => [
              %{
                "id" => 27205,
                "title" => "Inception",
                "overview" => "dream heist",
                "release_date" => "2010-07-16",
                "poster_path" => "/poster.jpg",
                "backdrop_path" => "/back.jpg"
              }
            ]
          })

        String.contains?(path, "/movie/27205") ->
          Req.Test.json(conn, %{
            "id" => 27205,
            "title" => "Inception",
            "overview" => "dream heist full",
            "release_date" => "2010-07-16",
            "poster_path" => "/poster.jpg",
            "backdrop_path" => "/back.jpg"
          })

        true ->
          conn
          |> Plug.Conn.put_resp_content_type("image/jpeg")
          |> Plug.Conn.send_resp(200, jpeg)
      end
    end)
  end
end
