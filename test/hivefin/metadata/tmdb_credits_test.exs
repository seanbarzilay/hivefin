defmodule Hivefin.Metadata.TMDbCreditsTest do
  use ExUnit.Case, async: true

  alias Hivefin.Metadata.TMDB

  defp payload do
    %{
      "id" => 10_113,
      "title" => "102 Dalmatians",
      "credits" => %{
        "cast" => [
          %{
            "id" => 3084,
            "name" => "Glenn Close",
            "character" => "Cruella De Vil",
            "order" => 0,
            "profile_path" => "/close.jpg"
          },
          %{
            "id" => 6162,
            "name" => "Ioan Gruffudd",
            "character" => "Kevin Shepherd",
            "order" => 1,
            "profile_path" => nil
          }
        ],
        "crew" => [
          %{
            "id" => 1,
            "name" => "Kevin Lima",
            "job" => "Director",
            "department" => "Directing",
            "profile_path" => "/lima.jpg"
          },
          %{
            "id" => 2,
            "name" => "Kristen Buckley",
            "job" => "Screenplay",
            "department" => "Writing",
            "profile_path" => nil
          },
          %{
            "id" => 3,
            "name" => "David Newman",
            "job" => "Original Music Composer",
            "department" => "Sound",
            "profile_path" => nil
          },
          %{
            "id" => 4,
            "name" => "Edward S. Feldman",
            "job" => "Producer",
            "department" => "Production",
            "profile_path" => nil
          },
          %{
            "id" => 5,
            "name" => "Some Body",
            "job" => "Best Boy Grip",
            "department" => "Camera",
            "profile_path" => nil
          }
        ]
      }
    }
  end

  test "cast maps to Actor with character and order" do
    people = TMDB.credits_from_payload(payload())
    cast = Enum.filter(people, &(&1.type == "Actor"))

    assert length(cast) == 2

    assert %{
             tmdb_id: 3084,
             name: "Glenn Close",
             role: "Cruella De Vil",
             sort_order: 0,
             profile_path: "/close.jpg"
           } = hd(cast)
  end

  test "crew jobs map to PersonKind values" do
    by_name = Map.new(TMDB.credits_from_payload(payload()), &{&1.name, &1.type})

    assert by_name["Kevin Lima"] == "Director"
    assert by_name["Kristen Buckley"] == "Writer"
    assert by_name["David Newman"] == "Composer"
    assert by_name["Edward S. Feldman"] == "Producer"
  end

  test "unknown crew jobs are dropped, not mapped to Unknown" do
    names = Enum.map(TMDB.credits_from_payload(payload()), & &1.name)

    refute "Some Body" in names
    refute "Unknown" in Enum.map(TMDB.credits_from_payload(payload()), & &1.type)
  end

  test "crew have an empty-string role, never nil" do
    # jellyfin-web may call .length/.trim on Role; null would throw.
    for p <- TMDB.credits_from_payload(payload()), p.type != "Actor" do
      assert p.role == ""
    end
  end

  test "cast sorts before crew, and cast keeps TMDb order" do
    people = TMDB.credits_from_payload(payload())
    types = Enum.map(people, & &1.type)

    assert Enum.take(types, 2) == ["Actor", "Actor"]
    assert Enum.map(Enum.take(people, 2), & &1.sort_order) == [0, 1]
  end

  test "a payload with no credits yields an empty list" do
    # Entries cached before append_to_response was added have no credits key.
    assert TMDB.credits_from_payload(%{"id" => 1, "title" => "Old Cache Entry"}) == []
    assert TMDB.credits_from_payload(%{}) == []
  end
end
