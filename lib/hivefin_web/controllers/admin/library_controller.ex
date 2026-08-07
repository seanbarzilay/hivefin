defmodule HivefinWeb.Admin.LibraryController do
  use HivefinWeb, :controller

  alias Hivefin.Library.LibraryContext
  alias Hivefin.Scanner

  def index(conn, _params) do
    libraries = LibraryContext.list_libraries_with_stats()
    running = MapSet.new(Scanner.running_ids())

    render(conn, :index,
      page_title: "Libraries",
      active: :libraries,
      current_user: conn.assigns.current_admin,
      libraries: libraries,
      running_ids: running,
      any_running?: MapSet.size(running) > 0,
      form: empty_form()
    )
  end

  def create(conn, %{"library" => params}) do
    attrs = %{
      name: params["name"],
      type: params["type"],
      path: params["path"]
    }

    case LibraryContext.create_library(attrs) do
      {:ok, library} ->
        conn
        |> put_flash(:info, "Library “#{library.name}” created. Click Scan to index media.")
        |> redirect(to: ~p"/admin/libraries")

      {:error, changeset} ->
        conn
        |> put_flash(:error, format_errors(changeset))
        |> redirect(to: ~p"/admin/libraries")
    end
  end

  def edit(conn, %{"id" => id}) do
    case LibraryContext.get_library(id) do
      nil ->
        conn
        |> put_flash(:error, "Library not found.")
        |> redirect(to: ~p"/admin/libraries")

      library ->
        render(conn, :edit,
          page_title: "Edit #{library.name}",
          active: :libraries,
          current_user: conn.assigns.current_admin,
          library: library
        )
    end
  end

  def update(conn, %{"id" => id, "library" => params}) do
    case LibraryContext.get_library(id) do
      nil ->
        conn
        |> put_flash(:error, "Library not found.")
        |> redirect(to: ~p"/admin/libraries")

      library ->
        case LibraryContext.update_library(library, %{
               name: params["name"],
               path: params["path"]
             }) do
          {:ok, updated} ->
            conn
            |> put_flash(:info, "Updated library “#{updated.name}”.")
            |> redirect(to: ~p"/admin/libraries")

          {:error, changeset} ->
            conn
            |> put_flash(:error, format_errors(changeset))
            |> redirect(to: ~p"/admin/libraries/#{library.id}/edit")
        end
    end
  end

  def scan(conn, %{"id" => id}) do
    case Scanner.scan_library(id) do
      :ok ->
        conn
        |> put_flash(:info, "Scan started.")
        |> redirect(to: ~p"/admin/libraries")

      {:error, :already_scanning} ->
        conn
        |> put_flash(:error, "A scan is already running for this library.")
        |> redirect(to: ~p"/admin/libraries")

      {:error, :not_found} ->
        conn
        |> put_flash(:error, "Library not found.")
        |> redirect(to: ~p"/admin/libraries")

      {:error, reason} ->
        conn
        |> put_flash(:error, "Could not start scan: #{inspect(reason)}")
        |> redirect(to: ~p"/admin/libraries")
    end
  end

  def scan_all(conn, _params) do
    result = Scanner.scan_all()
    started = length(result.started)
    skipped = length(result.skipped)
    errors = length(result.errors)

    msg =
      cond do
        started == 0 and skipped > 0 and errors == 0 ->
          "All libraries already scanning."

        started == 0 and errors > 0 ->
          "No scans started (#{errors} error(s))."

        true ->
          "Started #{started} scan(s)" <>
            if(skipped > 0, do: ", skipped #{skipped}", else: "") <>
            if(errors > 0, do: ", #{errors} error(s)", else: "") <> "."
      end

    conn
    |> put_flash(if(errors > 0 and started == 0, do: :error, else: :info), msg)
    |> redirect(to: ~p"/admin/libraries")
  end

  def cancel_scan(conn, %{"id" => id}) do
    :ok = Scanner.cancel(id)

    conn
    |> put_flash(:info, "Scan cancel requested.")
    |> redirect(to: ~p"/admin/libraries")
  end

  def delete(conn, %{"id" => id}) do
    case LibraryContext.delete_library(id) do
      {:ok, library} ->
        conn
        |> put_flash(:info, "Deleted library “#{library.name}”.")
        |> redirect(to: ~p"/admin/libraries")

      {:error, :not_found} ->
        conn
        |> put_flash(:error, "Library not found.")
        |> redirect(to: ~p"/admin/libraries")

      {:error, _} ->
        conn
        |> put_flash(:error, "Could not delete library.")
        |> redirect(to: ~p"/admin/libraries")
    end
  end

  defp empty_form do
    %{"name" => "", "type" => "movies", "path" => ""}
  end

  defp format_errors(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> Enum.map(fn {field, messages} -> "#{field} #{Enum.join(messages, ", ")}" end)
    |> Enum.join("; ")
  end
end
