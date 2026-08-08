defmodule Hivefin.Metadata.PersonImageTest do
  use Hivefin.DataCase, async: true

  alias Hivefin.Library.Person
  alias Hivefin.Metadata.ImageCache
  alias Hivefin.Repo

  setup do
    {:ok, person} =
      %Person{}
      |> Person.changeset(%{name: "Glenn Close", provider_ids: %{"Tmdb" => "3084"}})
      |> Repo.insert()

    {:ok, person: person}
  end

  test "an images row can belong to a person", %{person: person} do
    {:ok, image} =
      %Hivefin.Library.Image{}
      |> Hivefin.Library.Image.changeset(%{
        person_id: person.id,
        type: :primary,
        local_path: "/tmp/x.jpg"
      })
      |> Repo.insert()

    assert image.person_id == person.id
    assert is_nil(image.item_id)
  end

  test "an images row cannot belong to both an item and a person" do
    # The DB constraint holds the invariant, not application code.
    # create_library validates the path exists on disk (see LibraryContext),
    # so the directory has to be real, unlike the brief's bare tmp path.
    path = Path.join(System.tmp_dir!(), "pi-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)

    {:ok, library} =
      Hivefin.Library.LibraryContext.create_library(%{
        name: "M-#{System.unique_integer([:positive])}",
        type: :movies,
        path: path
      })

    {:ok, item} =
      %Hivefin.Library.Item{}
      |> Hivefin.Library.Item.changeset(%{
        name: "X",
        type: :movie,
        sort_name: "x",
        library_id: library.id
      })
      |> Repo.insert()

    {:ok, person} = %Person{} |> Person.changeset(%{name: "Both"}) |> Repo.insert()

    assert_raise Ecto.ConstraintError, fn ->
      %Hivefin.Library.Image{}
      |> Hivefin.Library.Image.changeset(%{
        item_id: item.id,
        person_id: person.id,
        type: :primary,
        local_path: "/tmp/y.jpg"
      })
      |> Repo.insert()
    end
  end

  test "an images row must belong to something" do
    assert_raise Ecto.ConstraintError, fn ->
      %Hivefin.Library.Image{}
      |> Hivefin.Library.Image.changeset(%{type: :primary, local_path: "/tmp/z.jpg"})
      |> Repo.insert()
    end
  end

  test "path_for resolves a person id", %{person: person} do
    path = Path.join(System.tmp_dir!(), "person-#{person.id}.jpg")
    File.write!(path, "not-really-a-jpeg")

    {:ok, _} =
      %Hivefin.Library.Image{}
      |> Hivefin.Library.Image.changeset(%{
        person_id: person.id,
        type: :primary,
        local_path: path
      })
      |> Repo.insert()

    assert {:ok, ^path} = ImageCache.path_for(person.id, "Primary")

    File.rm(path)
  end

  test "path_for returns :error for an unknown id" do
    assert :error = ImageCache.path_for(Ecto.UUID.generate(), "Primary")
  end
end
