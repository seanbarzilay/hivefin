defmodule Hivefin.Library.PersonTest do
  use Hivefin.DataCase, async: true

  alias Hivefin.Library.{Item, ItemPerson, Person}
  alias Hivefin.Repo

  test "changeset requires a name and derives sort_name" do
    assert %{valid?: false} = Person.changeset(%Person{}, %{})

    cs = Person.changeset(%Person{}, %{name: "Glenn Close"})
    assert cs.valid?
    assert Ecto.Changeset.get_field(cs, :sort_name) == "glenn close"
  end

  test "people are unique per TMDb id" do
    attrs = %{name: "Glenn Close", provider_ids: %{"Tmdb" => "3084"}}
    assert {:ok, _} = %Person{} |> Person.changeset(attrs) |> Repo.insert()

    assert {:error, _} =
             %Person{}
             |> Person.changeset(%{name: "Glenn Close (dup)", provider_ids: %{"Tmdb" => "3084"}})
             |> Repo.insert()
  end

  test "a person with no TMDb id is allowed more than once" do
    # The unique index is on the extracted Tmdb key, which is NULL here, and
    # Postgres does not consider NULLs equal.
    for n <- ["Uncredited A", "Uncredited B"] do
      assert {:ok, _} = %Person{} |> Person.changeset(%{name: n}) |> Repo.insert()
    end
  end

  test "item_people links an item to a person with a role and kind" do
    tmp_path = Path.join(System.tmp_dir!(), "people-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_path)
    on_exit(fn -> File.rm_rf(tmp_path) end)

    {:ok, library} =
      Hivefin.Library.LibraryContext.create_library(%{
        name: "M",
        type: :movies,
        path: tmp_path
      })

    {:ok, item} =
      %Item{}
      |> Item.changeset(%{
        name: "101 Dalmatians",
        type: :movie,
        sort_name: "101",
        library_id: library.id
      })
      |> Repo.insert()

    {:ok, person} = %Person{} |> Person.changeset(%{name: "Glenn Close"}) |> Repo.insert()

    assert {:ok, link} =
             %ItemPerson{}
             |> ItemPerson.changeset(%{
               item_id: item.id,
               person_id: person.id,
               role: "Cruella De Vil",
               type: "Actor",
               sort_order: 0
             })
             |> Repo.insert()

    assert link.type == "Actor"
    assert link.role == "Cruella De Vil"
  end

  test "item_people requires a type" do
    assert %{valid?: false} = ItemPerson.changeset(%ItemPerson{}, %{role: "X"})
  end
end
