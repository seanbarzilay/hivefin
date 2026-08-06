defmodule HivefinWeb.Compat.JellyfinShapeTest do
  use ExUnit.Case, async: true

  alias Hivefin.JellyfinShape

  test "assert_shape accepts matching map" do
    actual = %{"Name" => "x", "Count" => 1, "Ok" => true}
    expected = %{"Name" => :string, "Count" => :integer, "Ok" => :boolean}
    assert actual == JellyfinShape.assert_shape(actual, expected)
  end

  test "assert_shape fails on missing key" do
    assert_raise ExUnit.AssertionError, ~r/missing Name/, fn ->
      JellyfinShape.assert_shape(%{}, %{"Name" => :string})
    end
  end

  test "assert_shape fails on bad type" do
    assert_raise ExUnit.AssertionError, ~r/bad type for Name/, fn ->
      JellyfinShape.assert_shape(%{"Name" => 1}, %{"Name" => :string})
    end
  end

  test "shape_from_sample nests lists and maps" do
    sample = %{
      "Items" => [%{"Id" => "a", "N" => 1}],
      "TotalRecordCount" => 1
    }

    shape = JellyfinShape.shape_from_sample(sample)

    assert shape["TotalRecordCount"] == :integer
    assert shape["Items"] == {:list, %{"Id" => :string, "N" => :integer}}
  end

  test "web fixtures load and have expected top-level keys" do
    for name <- [
          "authenticate_by_name",
          "system_info_public",
          "system_info",
          "views",
          "items_list",
          "playback_info"
        ] do
      fixture = JellyfinShape.load_fixture("web", name)
      assert is_map(fixture)
      assert map_size(fixture) > 0
    end
  end

  test "androidtv fixtures load (hand-authored, not live capture)" do
    fixture = JellyfinShape.load_fixture("androidtv", "authenticate_by_name")
    assert fixture["SessionInfo"]["Client"] == "Android TV"
  end
end
