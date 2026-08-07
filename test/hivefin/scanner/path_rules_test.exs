defmodule Hivefin.Scanner.PathRulesTest do
  use ExUnit.Case, async: true

  alias Hivefin.Scanner.PathRules

  test "identifies video extensions" do
    assert PathRules.video_file?("movie.mp4")
    assert PathRules.video_file?("movie.MKV")
    assert PathRules.video_file?("clip.webm")
    assert PathRules.video_file?("film.mov")
    assert PathRules.video_file?("show.mpg")
    refute PathRules.video_file?("readme.txt")
    refute PathRules.video_file?("poster.jpg")
  end

  test "ignores special directory and file names" do
    assert PathRules.ignored_name?(".DS_Store")
    assert PathRules.ignored_name?(".hidden")
    assert PathRules.ignored_name?("@eaDir")
    assert PathRules.ignored_name?("Extras")
    assert PathRules.ignored_name?("samples")
    refute PathRules.ignored_name?("Big Buck Bunny (2008)")
    refute PathRules.ignored_name?("Season 01")
  end
end

defmodule Hivefin.Scanner.WalkerTest do
  use ExUnit.Case, async: true

  alias Hivefin.Scanner.Walker

  test "recursively finds videos in nested movie folders" do
    root = Path.expand("test/support/fixtures/media_tree/movies", File.cwd!())
    assert {:ok, files} = Walker.list_video_files(root)
    assert length(files) >= 1
    assert Enum.any?(files, &String.ends_with?(&1, ".mp4"))
  end

  test "returns error for missing root" do
    assert {:error, :enoent} = Walker.list_video_files("/nonexistent/hivefin-scan-root")
  end
end
