defmodule Hivefin.Jellyfin.Dto.BaseItemTest do
  use ExUnit.Case, async: true

  alias Hivefin.Jellyfin.Id

  alias Hivefin.Jellyfin.Dto.BaseItem
  alias Hivefin.Jellyfin.Dto.SdkRequired
  alias Hivefin.Library.{Item, Library, MediaSource, MediaStream, Person}

  # Listed literally, not read from the implementation — a test that derives
  # its expectations from the code under test agrees with a regression
  # instead of catching one. `Id`/`Type` are the two jellyfin-sdk-kotlin has
  # no default for; the rest are SDK-optional but emitted anyway because
  # jellyfin-web's generic card/list rendering dereferences them without a
  # null guard regardless of item Type (see from_person/1's moduledoc).
  @person_dto_keys ~w(Id Name ServerId Type IsFolder PlayAccess LocationType SortName ProviderIds ImageTags UserData)

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
    assert dto["MediaType"] == "Video"
    assert dto["Name"] == "X"
    assert dto["Id"] == Id.format(id)
    assert dto["ProductionYear"] == 2008
    assert dto["IsFolder"] == false
    assert dto["SortName"] == "x"
    assert dto["ParentId"] == Id.format(library_id)
    assert dto["ImageTags"] == %{}
    assert dto["UserData"]["Played"] == false
    assert dto["UserData"]["PlaybackPositionTicks"] == 0
    # Always present for playable types (empty when sources not preloaded)
    assert dto["MediaSources"] == []
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

    assert BaseItem.from_item(item)["ParentId"] == Id.format(parent_id)
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

  test "season DTO includes SeriesId and IndexNumber" do
    series_id = Ecto.UUID.generate()

    season = %Item{
      id: Ecto.UUID.generate(),
      library_id: Ecto.UUID.generate(),
      parent_id: series_id,
      name: "Season 1",
      type: :season,
      index_number: 1,
      sort_name: "season 1"
    }

    dto = BaseItem.from_item(season)
    assert dto["Type"] == "Season"
    assert dto["SeriesId"] == Id.format(series_id)
    assert dto["IndexNumber"] == 1
    assert dto["ParentId"] == Id.format(series_id)
    refute Map.has_key?(dto, "SeasonId")
  end

  test "episode DTO includes SeriesId, SeasonId, IndexNumber, ParentIndexNumber" do
    series_id = Ecto.UUID.generate()
    season_id = Ecto.UUID.generate()

    season = %Item{
      id: season_id,
      parent_id: series_id,
      type: :season,
      name: "Season 1",
      index_number: 1
    }

    episode = %Item{
      id: Ecto.UUID.generate(),
      library_id: Ecto.UUID.generate(),
      parent_id: season_id,
      parent: season,
      name: "Episode 2",
      type: :episode,
      index_number: 2,
      parent_index_number: 1,
      sort_name: "episode 2"
    }

    dto = BaseItem.from_item(episode)
    assert dto["Type"] == "Episode"
    assert dto["SeasonId"] == Id.format(season_id)
    assert dto["SeriesId"] == Id.format(series_id)
    assert dto["IndexNumber"] == 2
    assert dto["ParentIndexNumber"] == 1
    assert dto["ParentId"] == Id.format(season_id)
  end

  test "maps library as CollectionFolder" do
    id = Ecto.UUID.generate()
    library = %Library{id: id, name: "Movies", type: :movies, path: "/media/movies"}

    dto = BaseItem.from_library(library)

    assert dto["Type"] == "CollectionFolder"
    assert dto["CollectionType"] == "movies"
    assert dto["Name"] == "Movies"
    assert dto["Id"] == Id.format(id)
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
          item_id: item_id,
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
    # Jellyfin convention: the primary MediaSource.Id is the *item* id — clients
    # resolve playback via getItem(mediaSource.Id) and a distinct source UUID 404s.
    assert source["Id"] == Id.format(item_id)
    assert source["Container"] == "mkv"
    assert source["Size"] == 123
    assert source["RunTimeTicks"] == 50_000_000
    # mkv is not browser-native; vue uses this flag to pick hls.js vs <video>
    assert source["SupportsDirectPlay"] == false
    assert source["SupportsDirectStream"] == false
    assert source["SupportsTranscoding"] == true
    refute Map.has_key?(source, "Path")
    assert [stream] = source["MediaStreams"]
    assert stream["Type"] == "Video"
    assert stream["Codec"] == "h264"
    assert stream["Width"] == 1920
    # jellyfin-vue stream pickers only render DisplayTitle
    assert stream["DisplayTitle"] == "1080p H264 - Default"

    # BaseItemDto.MediaSources is deserialized into the same strict Kotlin
    # MediaSourceInfo/MediaStream models as PlaybackInfo, on every item fetch.
    # A missing required field raises MissingFieldException client-side.
    for key <- SdkRequired.source_keys() do
      assert Map.has_key?(source, key), "MediaSourceInfo missing required key #{key}"
      refute is_nil(source[key]), "MediaSourceInfo required key #{key} is null"
    end

    for key <- SdkRequired.stream_keys() do
      assert Map.has_key?(stream, key), "MediaStream missing required key #{key}"
      refute is_nil(stream[key]), "MediaStream required key #{key} is null"
    end
  end

  test "mp4 h264/aac MediaSources mark browser DirectPlay true" do
    item = %Item{
      id: Ecto.UUID.generate(),
      name: "Y",
      type: :movie,
      sort_name: "y",
      media_sources: [
        %MediaSource{
          id: Ecto.UUID.generate(),
          path: "/secret/media/movie.mp4",
          container: "mp4",
          media_streams: [
            %MediaStream{
              id: Ecto.UUID.generate(),
              index: 0,
              type: :video,
              codec: "h264",
              width: 1280,
              height: 720,
              is_default: true,
              is_forced: false
            },
            %MediaStream{
              id: Ecto.UUID.generate(),
              index: 1,
              type: :audio,
              codec: "aac",
              channels: 2,
              is_default: true,
              is_forced: false
            }
          ]
        }
      ]
    }

    dto = BaseItem.from_item(item, fields: ["MediaSources"])
    assert [source] = dto["MediaSources"]
    assert source["SupportsDirectPlay"] == true
    assert source["SupportsDirectStream"] == true
  end

  test "hevc MediaSources mark browser DirectPlay false" do
    item = %Item{
      id: Ecto.UUID.generate(),
      name: "Z",
      type: :movie,
      sort_name: "z",
      media_sources: [
        %MediaSource{
          id: Ecto.UUID.generate(),
          path: "/secret/media/movie.mp4",
          container: "mp4",
          media_streams: [
            %MediaStream{
              id: Ecto.UUID.generate(),
              index: 0,
              type: :video,
              codec: "hevc",
              width: 3840,
              height: 2160,
              is_default: true,
              is_forced: false
            }
          ]
        }
      ]
    }

    dto = BaseItem.from_item(item, fields: ["MediaSources"])
    assert [source] = dto["MediaSources"]
    assert source["SupportsDirectPlay"] == false
  end

  test "person DTO carries every field jellyfin-web dereferences unconditionally" do
    person = %Person{
      id: Ecto.UUID.generate(),
      name: "Glenn Close",
      sort_name: "glenn close",
      provider_ids: %{"Tmdb" => "3084"},
      profile_path: nil
    }

    dto = BaseItem.from_person(person)

    assert dto["Type"] == "Person"
    assert dto["Name"] == "Glenn Close"
    assert dto["Id"] == Id.format(person.id)
    assert dto["IsFolder"] == false
    assert dto["SortName"] == "glenn close"
    assert dto["ProviderIds"] == %{"Tmdb" => "3084"}
    assert dto["ImageTags"] == %{}

    for key <- @person_dto_keys do
      assert Map.has_key?(dto, key), "Person BaseItemDto missing #{key}"
      refute is_nil(dto[key]), "Person BaseItemDto required key #{key} is null"
    end
  end

  test "person DTO has no profile_path: PrimaryImageTag is absent, not null" do
    person = %Person{
      id: Ecto.UUID.generate(),
      name: "No Photo",
      sort_name: "no photo",
      provider_ids: %{},
      profile_path: nil
    }

    dto = BaseItem.from_person(person)

    refute Map.has_key?(dto, "PrimaryImageTag")
    assert dto["ImageTags"] == %{}
  end

  test "person DTO PrimaryImageTag is the same hash person_entry/1 emits for the same profile_path" do
    path = "/abc123.jpg"

    person = %Person{
      id: Ecto.UUID.generate(),
      name: "Headshot Haver",
      sort_name: "headshot haver",
      provider_ids: %{},
      profile_path: path
    }

    # Same person, rendered through from_item's People field (person_entry/1)
    # — must produce the identical tag, proving there is exactly one hashing
    # implementation, not two that could drift apart.
    item = %Item{
      id: Ecto.UUID.generate(),
      name: "M",
      type: :movie,
      sort_name: "m",
      item_people: [%{person: person, role: "", type: "Actor", sort_order: 0}]
    }

    [people_entry] = BaseItem.from_item(item, fields: ["People"])["People"]
    person_dto = BaseItem.from_person(person)

    expected = :crypto.hash(:md5, path) |> Base.encode16(case: :lower)

    assert person_dto["PrimaryImageTag"] == expected
    assert people_entry["PrimaryImageTag"] == expected
  end

  test "builds DisplayTitle and ChannelLayout for audio streams" do
    item = %Item{
      id: Ecto.UUID.generate(),
      name: "X",
      type: :movie,
      sort_name: "x",
      media_sources: [
        %MediaSource{
          id: Ecto.UUID.generate(),
          path: "/secret/media/movie.mkv",
          container: "mkv",
          media_streams: [
            %MediaStream{
              id: Ecto.UUID.generate(),
              index: 1,
              type: :audio,
              codec: "aac",
              language: "eng",
              channels: 2,
              is_default: true,
              is_forced: false
            }
          ]
        }
      ]
    }

    dto = BaseItem.from_item(item, fields: ["MediaSources"])
    assert [stream] = hd(dto["MediaSources"])["MediaStreams"]
    assert stream["Type"] == "Audio"
    assert stream["ChannelLayout"] == "2.0"
    assert stream["DisplayTitle"] == "English AAC Stereo - Default"
  end
end
