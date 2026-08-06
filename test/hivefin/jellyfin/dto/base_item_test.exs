defmodule Hivefin.Jellyfin.Dto.BaseItemTest do
  use ExUnit.Case, async: true

  alias Hivefin.Jellyfin.Dto.BaseItem
  alias Hivefin.Library.{Item, Library, MediaSource, MediaStream}

  test "maps movie item" do
    id = Ecto.UUID.generate()
    library_id = Ecto.UUID.generate()

    item = %Item{
      id: id,
      library_id: library_id,
      name: "X",
      type: :movie,
      production_year: 2008,
      sort_name: "x",
      parent_id: nil
    }

    dto = BaseItem.from_item(item, user_data: nil)

    assert dto["Type"] == "Movie"
    assert dto["Name"] == "X"
    assert dto["Id"] == id
    assert dto["ProductionYear"] == 2008
    assert dto["IsFolder"] == false
    assert dto["SortName"] == "x"
    assert dto["ParentId"] == library_id
    assert dto["ImageTags"] == %{}
    assert dto["UserData"]["Played"] == false
    assert dto["UserData"]["PlaybackPositionTicks"] == 0
    refute Map.has_key?(dto, "MediaSources")
  end

  test "ParentId prefers item parent over library for nested items" do
    library_id = Ecto.UUID.generate()
    parent_id = Ecto.UUID.generate()

    item = %Item{
      id: Ecto.UUID.generate(),
      library_id: library_id,
      parent_id: parent_id,
      name: "Ep",
      type: :episode,
      sort_name: "ep"
    }

    assert BaseItem.from_item(item)["ParentId"] == parent_id
  end

  test "maps series/season/episode types" do
    for {type, expected} <- [
          {:series, "Series"},
          {:season, "Season"},
          {:episode, "Episode"}
        ] do
      item = %Item{
        id: Ecto.UUID.generate(),
        library_id: Ecto.UUID.generate(),
        name: "N",
        type: type,
        sort_name: "n"
      }

      assert BaseItem.from_item(item)["Type"] == expected
    end
  end

  test "maps library as CollectionFolder" do
    id = Ecto.UUID.generate()
    library = %Library{id: id, name: "Movies", type: :movies, path: "/media/movies"}

    dto = BaseItem.from_library(library)

    assert dto["Type"] == "CollectionFolder"
    assert dto["CollectionType"] == "movies"
    assert dto["Name"] == "Movies"
    assert dto["Id"] == id
    assert dto["IsFolder"] == true
    refute Map.has_key?(dto, "Path")
  end

  test "includes MediaSources without filesystem Path when requested" do
    item_id = Ecto.UUID.generate()
    source_id = Ecto.UUID.generate()

    item = %Item{
      id: item_id,
      name: "X",
      type: :movie,
      sort_name: "x",
      media_sources: [
        %MediaSource{
          id: source_id,
          path: "/secret/media/movie.mkv",
          container: "mkv",
          size: 123,
          bitrate: 1000,
          duration_ticks: 50_000_000,
          media_streams: [
            %MediaStream{
              id: Ecto.UUID.generate(),
              index: 0,
              type: :video,
              codec: "h264",
              width: 1920,
              height: 1080,
              is_default: true,
              is_forced: false
            }
          ]
        }
      ]
    }

    dto = BaseItem.from_item(item, fields: ["MediaSources"])

    assert [source] = dto["MediaSources"]
    assert source["Id"] == source_id
    assert source["Container"] == "mkv"
    assert source["Size"] == 123
    assert source["RunTimeTicks"] == 50_000_000
    refute Map.has_key?(source, "Path")
    assert [stream] = source["MediaStreams"]
    assert stream["Type"] == "Video"
    assert stream["Codec"] == "h264"
    assert stream["Width"] == 1920
  end
end
