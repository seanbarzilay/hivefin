defmodule Hivefin.Scanner.ScannerTest do
  use Hivefin.DataCase, async: false

  alias Hivefin.Library.LibraryContext
  alias Hivefin.Scanner
  alias Hivefin.Scanner.PathRules

  @movies_path Path.expand("test/support/fixtures/media_tree/movies", File.cwd!())

  test "scan imports movie and media source" do
    {:ok, lib} =
      LibraryContext.create_library(%{name: "Movies", type: :movies, path: @movies_path})

    assert :ok = Scanner.scan_library_sync(lib.id)

    items = LibraryContext.list_items(lib.id, type: :movie)
    assert length(items) == 1
    assert hd(items).name =~ "Big Buck Bunny"
    assert hd(items).production_year == 2008
    assert is_nil(hd(items).parent_id)

    assert [%{path: p}] = LibraryContext.list_media_sources(hd(items).id)
    assert File.exists?(p)
    assert PathRules.under_root?(lib.path, p)

    lib = LibraryContext.get_library!(lib.id)
    assert lib.last_scanned_at
  end

  test "scan is idempotent for unchanged files" do
    {:ok, lib} =
      LibraryContext.create_library(%{name: "Movies", type: :movies, path: @movies_path})

    assert :ok = Scanner.scan_library_sync(lib.id)
    assert :ok = Scanner.scan_library_sync(lib.id)

    items = LibraryContext.list_items(lib.id, type: :movie)
    assert length(items) == 1
    assert length(LibraryContext.list_media_sources(hd(items).id)) == 1
  end

  test "rejects media paths outside library root" do
    assert PathRules.under_root?("/media/movies", "/media/movies/foo.mp4")
    assert PathRules.under_root?("/media/movies", "/media/movies")
    refute PathRules.under_root?("/media/movies", "/media/other/foo.mp4")
    refute PathRules.under_root?("/media/movies", "/media/movies_backup/foo.mp4")
    refute PathRules.under_root?("/media/movies", "/etc/passwd")
  end

  test "create_library requires existing directory" do
    assert {:error, changeset} =
             LibraryContext.create_library(%{
               name: "Missing",
               type: :movies,
               path: "/tmp/hivefin-does-not-exist-#{System.unique_integer([:positive])}"
             })

    assert %{path: _} = errors_on(changeset)
  end

  test "list_libraries returns created libraries" do
    {:ok, _} =
      LibraryContext.create_library(%{name: "Movies", type: :movies, path: @movies_path})

    assert Enum.any?(LibraryContext.list_libraries(), &(&1.name == "Movies"))
  end
end
