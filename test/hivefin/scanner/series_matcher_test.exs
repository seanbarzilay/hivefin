defmodule Hivefin.Scanner.SeriesMatcherTest do
  use ExUnit.Case, async: true

  alias Hivefin.Scanner.SeriesMatcher

  test "parses space-separated SxxExx" do
    assert %{season: 1, episode: 2} = SeriesMatcher.parse_filename("Foo S01E02.mkv")
  end

  test "parses dotted SxxExx with quality tags" do
    assert %{season: 1, episode: 2} = SeriesMatcher.parse_filename("Foo.S01E02.720p.mkv")
  end

  test "parses lowercase sxxexx" do
    assert %{season: 3, episode: 11} = SeriesMatcher.parse_filename("Show.Name.s03e11.mkv")
  end

  test "parses multi-digit season and episode" do
    assert %{season: 12, episode: 105} = SeriesMatcher.parse_filename("Show S12E105.mp4")
  end

  test "returns nil when no season/episode marker" do
    assert is_nil(SeriesMatcher.parse_filename("random video.mkv"))
  end

  test "parses season folder names" do
    assert 1 == SeriesMatcher.parse_season_folder("Season 01")
    assert 1 == SeriesMatcher.parse_season_folder("Season 1")
    assert 2 == SeriesMatcher.parse_season_folder("season 02")
    assert is_nil(SeriesMatcher.parse_season_folder("Specials"))
    assert is_nil(SeriesMatcher.parse_season_folder("Show Name"))
  end
end
