defmodule Hivefin.Scanner.PathRulesTest do
  use ExUnit.Case, async: true

  alias Hivefin.Scanner.PathRules

  test "identifies video extensions" do
    assert PathRules.video_file?("movie.mp4")
    assert PathRules.video_file?("movie.MKV")
    assert PathRules.video_file?("clip.webm")
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
