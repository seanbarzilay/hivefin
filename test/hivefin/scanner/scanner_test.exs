defmodule Hivefin.Scanner.ScannerTest do
  use Hivefin.DataCase, async: false

  alias Hivefin.Library.LibraryContext
  alias Hivefin.Library.MediaStream
  alias Hivefin.Repo
  alias Hivefin.Scanner
  alias Hivefin.Scanner.PathRules

  @movies_path Path.expand("test/support/fixtures/media_tree/movies", File.cwd!())

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

  test "scan imports movie and media source" do
    {:ok, lib} =
      LibraryContext.create_library(%{name: "Movies", type: :movies, path: @movies_path})

    assert :ok = Scanner.scan_library_sync(lib.id)

    items = LibraryContext.list_items(lib.id, type: :movie)
    assert length(items) == 1
    assert hd(items).name =~ "Big Buck Bunny"
    assert hd(items).production_year == 2008
    assert is_nil(hd(items).parent_id)

    assert [%{path: p} = source] = LibraryContext.list_media_sources(hd(items).id)
    assert File.exists?(p)
    assert PathRules.under_root?(lib.path, p)
    assert source.media_streams != []

    lib = LibraryContext.get_library!(lib.id)
    assert lib.last_scanned_at

    job = LibraryContext.get_latest_scan_job(lib.id)
    assert job.status == :completed
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

  test "unchanged rescan does not require ffprobe" do
    {:ok, lib} =
      LibraryContext.create_library(%{name: "Movies", type: :movies, path: @movies_path})

    assert :ok = Scanner.scan_library_sync(lib.id)

    old = Application.get_env(:hivefin, :ffprobe_path)

    Application.put_env(
      :hivefin,
      :ffprobe_path,
      "/nonexistent/ffprobe-#{System.unique_integer()}"
    )

    on_exit(fn -> Application.put_env(:hivefin, :ffprobe_path, old) end)

    assert :ok = Scanner.scan_library_sync(lib.id)

    [%{media_streams: streams}] =
      LibraryContext.list_media_sources(hd(LibraryContext.list_items(lib.id)).id)

    assert streams != []
  end

  test "keeps existing streams when re-probe fails after size change" do
    {:ok, lib} =
      LibraryContext.create_library(%{name: "Movies", type: :movies, path: @movies_path})

    assert :ok = Scanner.scan_library_sync(lib.id)

    item = hd(LibraryContext.list_items(lib.id, type: :movie))
    [source] = LibraryContext.list_media_sources(item.id)
    stream_count = length(source.media_streams)
    assert stream_count > 0

    # Force "changed" without replacing the real file
    source
    |> Ecto.Changeset.change(size: 1)
    |> Repo.update!()

    old = Application.get_env(:hivefin, :ffprobe_path)

    Application.put_env(
      :hivefin,
      :ffprobe_path,
      "/nonexistent/ffprobe-#{System.unique_integer()}"
    )

    on_exit(fn -> Application.put_env(:hivefin, :ffprobe_path, old) end)

    assert :ok = Scanner.scan_library_sync(lib.id)

    [source_after] = LibraryContext.list_media_sources(item.id)
    assert length(source_after.media_streams) == stream_count

    assert Enum.map(source_after.media_streams, & &1.id) ==
             Enum.map(source.media_streams, & &1.id)
  end

  test "rejects media paths outside library root" do
    root =
      Path.join(System.tmp_dir!(), "hivefin-root-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    inside = Path.join(root, "foo.mp4")
    File.write!(inside, "x")

    outside_dir =
      Path.join(System.tmp_dir!(), "hivefin-outside-#{System.unique_integer([:positive])}")

    File.mkdir_p!(outside_dir)
    outside = Path.join(outside_dir, "secret.mp4")
    File.write!(outside, "y")

    on_exit(fn ->
      File.rm_rf(root)
      File.rm_rf(outside_dir)
    end)

    assert PathRules.under_root?(root, inside)
    assert PathRules.under_root?(root, root)
    refute PathRules.under_root?(root, outside)
    refute PathRules.under_root?(root, Path.join(root <> "_backup", "foo.mp4"))
    refute PathRules.under_root?(root, "/etc/passwd")
  end

  test "rejects symlink under library root that escapes outside" do
    root =
      Path.join(System.tmp_dir!(), "hivefin-symlink-root-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)

    outside =
      Path.join(
        System.tmp_dir!(),
        "hivefin-symlink-out-#{System.unique_integer([:positive])}.mp4"
      )

    File.write!(outside, "escaped")

    link = Path.join(root, "evil.mp4")
    File.ln_s!(outside, link)

    on_exit(fn ->
      File.rm_rf(root)
      File.rm(outside)
    end)

    # Path is lexically under root, but realpath escapes.
    assert String.starts_with?(Path.expand(link), Path.expand(root))
    refute PathRules.under_root?(root, link)
    assert {:ok, real} = PathRules.realpath(link)
    assert {:ok, outside_real} = PathRules.realpath(outside)
    assert real == outside_real
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

  test "second scan_library while running returns already_scanning" do
    {:ok, lib} =
      LibraryContext.create_library(%{name: "Movies", type: :movies, path: @movies_path})

    Application.put_env(:hivefin, :scanner_test_delay_ms, 300)

    assert :ok = Scanner.scan_library(lib.id)
    assert {:error, :already_scanning} = Scanner.scan_library(lib.id)

    assert :ok = Scanner.cancel(lib.id)

    # Allow in-flight shutdown to settle
    Process.sleep(50)

    job = LibraryContext.get_latest_scan_job(lib.id)
    assert job.status == :cancelled
  end

  test "cancel marks scan job cancelled and does not set last_scanned_at" do
    {:ok, lib} =
      LibraryContext.create_library(%{name: "Movies", type: :movies, path: @movies_path})

    assert is_nil(lib.last_scanned_at)

    Application.put_env(:hivefin, :scanner_test_delay_ms, 500)

    assert :ok = Scanner.scan_library(lib.id)
    assert :ok = Scanner.cancel(lib.id)

    Process.sleep(50)

    job = LibraryContext.get_latest_scan_job(lib.id)
    assert job.status == :cancelled

    lib = LibraryContext.get_library!(lib.id)
    assert is_nil(lib.last_scanned_at)
  end

  test "cooperative cancel via ETS finalizes job as cancelled without last_scanned_at" do
    {:ok, lib} =
      LibraryContext.create_library(%{name: "Movies", type: :movies, path: @movies_path})

    # Mid-scan soft cancel: test hook sets ETS flag; pipeline must not complete
    # as :completed or touch last_scanned_at.
    Application.put_env(:hivefin, :scanner_test_hook, fn library_id ->
      :ets.insert(:hivefin_scanner_cancel, {library_id, true})
    end)

    assert {:error, :cancelled} = Scanner.scan_library_sync(lib.id)

    job = LibraryContext.get_latest_scan_job(lib.id)
    assert job.status == :cancelled

    lib = LibraryContext.get_library!(lib.id)
    assert is_nil(lib.last_scanned_at)
  end

  test "list media streams association loaded after scan" do
    {:ok, lib} =
      LibraryContext.create_library(%{name: "Movies", type: :movies, path: @movies_path})

    assert :ok = Scanner.scan_library_sync(lib.id)
    [source] = LibraryContext.list_media_sources(hd(LibraryContext.list_items(lib.id)).id)
    assert Enum.any?(source.media_streams, &(&1.type == :video))
    assert %MediaStream{} = hd(source.media_streams)
  end
end
