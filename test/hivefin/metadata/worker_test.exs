defmodule Hivefin.Metadata.WorkerTest do
  use Hivefin.DataCase, async: true

  alias Hivefin.Library.{Image, Item, LibraryContext, PeopleContext}
  alias Hivefin.Metadata.Worker
  alias Hivefin.Repo

  defp make_movie(name, opts \\ []) do
    path = Path.join(System.tmp_dir!(), "worker-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf(path) end)

    {:ok, library} =
      LibraryContext.create_library(%{
        name: "L-#{System.unique_integer([:positive])}",
        type: :movies,
        path: path
      })

    {:ok, item} =
      %Item{}
      |> Item.changeset(%{
        name: name,
        type: :movie,
        sort_name: String.downcase(name),
        library_id: library.id,
        provider_ids: Keyword.get(opts, :provider_ids, %{"Tmdb" => "123"})
      })
      |> Repo.insert()

    if Keyword.get(opts, :image, true) do
      {:ok, _} =
        %Image{}
        |> Image.changeset(%{type: :primary, item_id: item.id})
        |> Repo.insert()
    end

    if Keyword.get(opts, :people, true) do
      assert {:ok, 1} =
               PeopleContext.replace_for_item(item.id, [
                 %{
                   tmdb_id: System.unique_integer([:positive]),
                   name: "Someone",
                   role: "",
                   type: "Director",
                   sort_order: nil,
                   profile_path: nil
                 }
               ])
    end

    item
  end

  test "fully-matched movie (poster + provider match + credits) is not returned" do
    item = make_movie("Complete")

    refute item.id in Worker.list_missing_movie_ids()
  end

  test "matched movie with poster and provider_ids but no credits is returned (backfill case)" do
    item = make_movie("No Credits", people: false)

    assert item.id in Worker.list_missing_movie_ids()
  end

  test "movie with no primary image is still returned" do
    item = make_movie("No Poster", image: false)

    assert item.id in Worker.list_missing_movie_ids()
  end

  test "movie with provider_ids stored as JSON null is still returned" do
    # The provider_ids column is NOT NULL at the DB level (jsonb, default
    # %{}) — Elixir `nil` can't round-trip through the changeset without
    # hitting that constraint. The fragment's 'null' branch instead guards
    # against a *present* jsonb value that is the JSON scalar null, which is
    # legal under NOT NULL. Force that value directly with raw SQL.
    item = make_movie("Nil Provider")
    Repo.query!("update items set provider_ids = 'null'::jsonb where id = '#{item.id}'")

    assert item.id in Worker.list_missing_movie_ids()
  end

  test "movie with empty-map provider_ids is still returned" do
    item = make_movie("Empty Provider", provider_ids: %{})

    assert item.id in Worker.list_missing_movie_ids()
  end

  test "limit caps the result" do
    for n <- 1..3, do: make_movie("Limited #{n}", people: false)

    assert length(Worker.list_missing_movie_ids(2)) == 2
  end
end
