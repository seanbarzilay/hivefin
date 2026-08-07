defmodule Hivefin.Library.UserDataTest do
  use Hivefin.DataCase, async: true

  alias Hivefin.Library.{LibraryContext, UserData}

  @movies_path Path.expand("test/support/fixtures/media_tree/movies", File.cwd!())

  setup do
    {:ok, user} =
      Hivefin.Accounts.create_user(%{
        name: "UD",
        username: "userdata",
        password: "password1",
        admin: false
      })

    {:ok, library} =
      LibraryContext.create_library(%{
        name: "Movies",
        type: :movies,
        path: @movies_path
      })

    {:ok, movie, :created} =
      LibraryContext.find_or_create_movie(library.id, %{
        name: "Big Buck Bunny",
        production_year: 2008
      })

    %{user: user, movie: movie}
  end

  test "1 second equals 10_000_000 ticks" do
    assert UserData.ticks_per_second() == 10_000_000
    assert UserData.seconds_to_ticks(1) == 10_000_000
    assert UserData.seconds_to_ticks(90) == 900_000_000
    assert UserData.ticks_to_seconds(10_000_000) == 1.0
  end

  test "upsert persists playback position ticks", %{user: user, movie: movie} do
    ticks = UserData.seconds_to_ticks(42)

    assert {:ok, ud} =
             UserData.upsert(user.id, movie.id, %{
               playback_position_ticks: ticks,
               played_percentage: 10.5,
               played: false
             })

    assert ud.user_id == user.id
    assert ud.item_id == movie.id
    assert ud.playback_position_ticks == ticks
    assert ud.played_percentage == 10.5
    assert ud.played == false
    assert %DateTime{} = ud.last_played_date

    reloaded = UserData.get(user.id, movie.id)
    assert reloaded.playback_position_ticks == ticks
  end

  test "upsert updates existing row without duplicating", %{user: user, movie: movie} do
    assert {:ok, first} =
             UserData.upsert(user.id, movie.id, %{playback_position_ticks: 100})

    assert {:ok, second} =
             UserData.upsert(user.id, movie.id, %{
               playback_position_ticks: 200,
               played: true,
               played_percentage: 100.0
             })

    assert first.id == second.id
    assert second.playback_position_ticks == 200
    assert second.played == true
    assert second.played_percentage == 100.0

    assert length(Repo.all(UserData)) == 1
  end

  test "map_for_items returns lookup by item_id", %{user: user, movie: movie} do
    assert {:ok, _} =
             UserData.upsert(user.id, movie.id, %{playback_position_ticks: 50})

    map = UserData.map_for_items(user.id, [movie.id, Ecto.UUID.generate()])
    assert Map.has_key?(map, movie.id)
    assert map[movie.id].playback_position_ticks == 50
  end

  test "upsert can clear resume position to zero (schema default)", %{user: user, movie: movie} do
    assert {:ok, _} =
             UserData.upsert(user.id, movie.id, %{
               playback_position_ticks: 60_000_000,
               played: false
             })

    assert {:ok, ud} =
             UserData.upsert(user.id, movie.id, %{
               playback_position_ticks: 0,
               played: true,
               played_percentage: 100.0
             })

    assert ud.playback_position_ticks == 0
    assert ud.played == true
    assert UserData.get(user.id, movie.id).playback_position_ticks == 0
  end

  test "partial upsert does not reset unmentioned fields", %{user: user, movie: movie} do
    assert {:ok, _} =
             UserData.upsert(user.id, movie.id, %{
               playback_position_ticks: 999,
               is_favorite: true,
               play_count: 3
             })

    assert {:ok, ud} =
             UserData.upsert(user.id, movie.id, %{playback_position_ticks: 1000})

    assert ud.playback_position_ticks == 1000
    assert ud.is_favorite == true
    assert ud.play_count == 3
  end
end
