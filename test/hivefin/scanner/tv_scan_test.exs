defmodule Hivefin.Scanner.TvScanTest do
  use Hivefin.DataCase, async: false

  alias Hivefin.Library.LibraryContext
  alias Hivefin.Repo
  alias Hivefin.Scanner
  alias Hivefin.Scanner.PathRules

  @tv_path Path.expand("test/support/fixtures/media_tree/tv", File.cwd!())
  @sample_mp4 Path.expand(
                "test/support/fixtures/media_tree/movies/Big Buck Bunny (2008)/Big Buck Bunny (2008).mp4",
                File.cwd!()
              )

  setup do
    owner = self()
    Application.put_env(:hivefin, :scanner_repo_owner, owner)
    Application.delete_env(:hivefin, :scanner_test_delay_ms)
    Application.delete_env(:hivefin, :scanner_test_hook)

    scanner = Process.whereis(Hivefin.Scanner)
    if scanner, do: Ecto.Adapters.SQL.Sandbox.allow(Repo, owner, scanner)

    on_exit(fn ->
      Application.delete_env(:hivefin, :scanner_repo_owner)
      Application.delete_env(:hivefin, :scanner_test_delay_ms)
      Application.delete_env(:hivefin, :scanner_test_hook)
    end)

    :ok
  end

  test "scan_library_sync for :tv creates series → season → episode + media_source" do
    {:ok, lib} =
      LibraryContext.create_library(%{name: "TV", type: :tv, path: @tv_path})

    assert :ok = Scanner.scan_library_sync(lib.id)

    series_items = LibraryContext.list_items(lib.id, type: :series)
    season_items = LibraryContext.list_items(lib.id, type: :season)
    episode_items = LibraryContext.list_items(lib.id, type: :episode)

    assert length(series_items) == 1
    assert length(season_items) == 1
    assert length(episode_items) == 1

    series = hd(series_items)
    season = hd(season_items)
    episode = hd(episode_items)

    assert series.name == "Big Buck Bunny"
    assert is_nil(series.parent_id)

    assert season.name == "Season 1"
    assert season.index_number == 1
    assert season.parent_id == series.id

    assert episode.name == "Episode 2"
    assert episode.index_number == 2
    assert episode.parent_index_number == 1
    assert episode.parent_id == season.id

    assert [%{path: p} = source] = LibraryContext.list_media_sources(episode.id)
    assert File.exists?(p)
    assert PathRules.under_root?(lib.path, p)
    assert source.media_streams != []

    lib = LibraryContext.get_library!(lib.id)
    assert lib.last_scanned_at

    job = LibraryContext.get_latest_scan_job(lib.id)
    assert job.status == :completed
    assert job.items_found == 1
    assert job.items_added == 1
  end

  test "TV scan is idempotent for unchanged files" do
    {:ok, lib} =
      LibraryContext.create_library(%{name: "TV", type: :tv, path: @tv_path})

    assert :ok = Scanner.scan_library_sync(lib.id)
    assert :ok = Scanner.scan_library_sync(lib.id)

    assert length(LibraryContext.list_items(lib.id, type: :series)) == 1
    assert length(LibraryContext.list_items(lib.id, type: :season)) == 1
    assert length(LibraryContext.list_items(lib.id, type: :episode)) == 1

    assert length(
             LibraryContext.list_media_sources(
               hd(LibraryContext.list_items(lib.id, type: :episode)).id
             )
           ) ==
             1
  end

  test "flat layout Series/file.mkv uses season from filename" do
    tmp = Path.join(System.tmp_dir!(), "hivefin-tv-flat-#{System.unique_integer([:positive])}")
    show_dir = Path.join(tmp, "Flat Show")
    File.mkdir_p!(show_dir)
    dest = Path.join(show_dir, "Flat Show S02E05.mp4")
    File.cp!(@sample_mp4, dest)

    on_exit(fn -> File.rm_rf(tmp) end)

    {:ok, lib} = LibraryContext.create_library(%{name: "TV Flat", type: :tv, path: tmp})
    assert :ok = Scanner.scan_library_sync(lib.id)

    [series] = LibraryContext.list_items(lib.id, type: :series)
    [season] = LibraryContext.list_items(lib.id, type: :season)
    [episode] = LibraryContext.list_items(lib.id, type: :episode)

    assert series.name == "Flat Show"
    assert season.index_number == 2
    assert season.parent_id == series.id
    assert episode.index_number == 5
    assert episode.parent_index_number == 2
    assert episode.parent_id == season.id
  end

  test "ParentId walk: library → series → seasons → episodes" do
    {:ok, lib} =
      LibraryContext.create_library(%{name: "TV", type: :tv, path: @tv_path})

    assert :ok = Scanner.scan_library_sync(lib.id)

    {root_items, root_total} = LibraryContext.list_items_for_parent(lib.id)
    assert root_total == 1
    assert [%{type: :series, name: "Big Buck Bunny"} = series] = root_items

    {seasons, season_total} = LibraryContext.list_items_for_parent(series.id)
    assert season_total == 1
    assert [%{type: :season, index_number: 1} = season] = seasons

    {episodes, ep_total} = LibraryContext.list_items_for_parent(season.id)
    assert ep_total == 1
    assert [%{type: :episode, index_number: 2} = episode] = episodes
    assert episode.parent_id == season.id
  end
end
