defmodule Hivefin.Library.MediaPathTest do
  use Hivefin.DataCase, async: true

  alias Hivefin.Library.LibraryContext
  alias Hivefin.Repo

  @movies_path Path.expand("test/support/fixtures/media_tree/movies", File.cwd!())
  @fixture_mp4 Path.expand(
                 "test/support/fixtures/media_tree/movies/Big Buck Bunny (2008)/Big Buck Bunny (2008).mp4",
                 File.cwd!()
               )

  setup do
    {:ok, library} =
      LibraryContext.create_library(%{
        name: "Movies",
        type: :movies,
        path: @movies_path
      })

    {:ok, movie, :created} =
      LibraryContext.find_or_create_movie(library.id, %{
        name: "Big Buck Bunny",
        production_year: 2008
      })

    stat = File.stat!(@fixture_mp4)
    {:ok, source, :created} = LibraryContext.upsert_media_source(movie.id, @fixture_mp4, stat)

    {:ok, library: library, movie: movie, source: source}
  end

  test "returns path for matching item and media source", %{movie: movie, source: source} do
    claims = %{item_id: movie.id, media_source_id: source.id}
    assert {:ok, path} = LibraryContext.media_path_for_item(movie.id, claims)
    assert path == Path.expand(source.path)
    assert File.regular?(path)
  end

  test "rejects claims when item_id does not match route item", %{
    movie: movie,
    source: source
  } do
    foreign_item = Ecto.UUID.generate()

    claims = %{item_id: foreign_item, media_source_id: source.id}
    assert {:error, :forbidden} = LibraryContext.media_path_for_item(movie.id, claims)
  end

  test "rejects media source that belongs to a different item", %{
    library: library,
    source: source
  } do
    {:ok, other, :created} =
      LibraryContext.find_or_create_movie(library.id, %{
        name: "Other Movie",
        production_year: 2010
      })

    # Claims target other item but use source owned by movie
    claims = %{item_id: other.id, media_source_id: source.id}
    assert {:error, :forbidden} = LibraryContext.media_path_for_item(other.id, claims)
  end

  test "rejects unknown media source id", %{movie: movie} do
    claims = %{item_id: movie.id, media_source_id: Ecto.UUID.generate()}
    assert {:error, :not_found} = LibraryContext.media_path_for_item(movie.id, claims)
  end

  test "rejects path outside library root", %{movie: movie, source: source} do
    outside =
      Path.join(System.tmp_dir!(), "hivefin-escape-#{System.unique_integer([:positive])}.mp4")

    File.write!(outside, "not under library")
    on_exit(fn -> File.rm(outside) end)

    source
    |> Ecto.Changeset.change(%{path: Path.expand(outside)})
    |> Repo.update!()

    claims = %{item_id: movie.id, media_source_id: source.id}
    assert {:error, :forbidden} = LibraryContext.media_path_for_item(movie.id, claims)
  end

  test "rejects when file is missing", %{movie: movie, source: source} do
    missing =
      Path.join(@movies_path, "missing-#{System.unique_integer([:positive])}.mp4")

    source
    |> Ecto.Changeset.change(%{path: Path.expand(missing)})
    |> Repo.update!()

    claims = %{item_id: movie.id, media_source_id: source.id}
    assert {:error, :not_found} = LibraryContext.media_path_for_item(movie.id, claims)
  end

  test "rejects symlink under library that points outside root", %{
    library: library,
    movie: movie,
    source: source
  } do
    outside =
      Path.join(
        System.tmp_dir!(),
        "hivefin-symlink-target-#{System.unique_integer([:positive])}.mp4"
      )

    File.cp!(@fixture_mp4, outside)

    link =
      Path.join(library.path, "escape-link-#{System.unique_integer([:positive])}.mp4")

    # Clean link first if leftover
    File.rm(link)
    File.ln_s!(outside, link)

    on_exit(fn ->
      File.rm(link)
      File.rm(outside)
    end)

    source
    |> Ecto.Changeset.change(%{path: Path.expand(link)})
    |> Repo.update!()

    claims = %{item_id: movie.id, media_source_id: source.id}
    assert {:error, :forbidden} = LibraryContext.media_path_for_item(movie.id, claims)
  end
end
