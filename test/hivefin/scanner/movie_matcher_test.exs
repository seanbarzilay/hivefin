defmodule Hivefin.Scanner.MovieMatcherTest do
  use ExUnit.Case, async: true

  alias Hivefin.Scanner.MovieMatcher

  test "parses movie folder name" do
    assert %{name: "Big Buck Bunny", year: 2008} =
             MovieMatcher.parse_name("Big Buck Bunny (2008)")
  end

  test "parses name without year" do
    assert %{name: "Inception", year: nil} = MovieMatcher.parse_name("Inception")
  end

  test "parses dotted year suffix" do
    assert %{name: "The Matrix", year: 1999} = MovieMatcher.parse_name("The.Matrix.1999")
  end

  test "strips file extension when given a filename" do
    assert %{name: "Big Buck Bunny", year: 2008} =
             MovieMatcher.parse_name("Big Buck Bunny (2008).mp4")
  end
end
