defmodule HivefinWeb.Jellyfin.PersonsController do
  @moduledoc """
  `GET /Persons` and `GET /Persons/{name}`.

  Jellyfin addresses a single person by **name**, not id — that is the
  upstream contract. Person DTOs are BaseItemDto-shaped with `Type: "Person"`
  (see `Hivefin.Jellyfin.Dto.BaseItem.from_person/1`).
  """
  use HivefinWeb, :controller

  alias Hivefin.Jellyfin.Dto.BaseItem
  alias Hivefin.Jellyfin.Params
  alias Hivefin.Library.PeopleContext

  @doc """
  `GET /Persons` — paged listing, optionally filtered by `SearchTerm`.

  `Limit` defaults inside `PeopleContext.list_people/1` when omitted (162,800
  rows in production — never attempt to return the whole table unpaged).
  """
  def index(conn, params) do
    start_index =
      Params.clamp_non_neg(parse_int(params["StartIndex"] || params["startIndex"])) || 0

    limit = Params.clamp_non_neg(parse_int(params["Limit"] || params["limit"]))
    search = params["SearchTerm"] || params["searchTerm"]

    {people, total} =
      PeopleContext.list_people(start_index: start_index, limit: limit, search_term: search)

    json(
      conn,
      BaseItem.query_result(Enum.map(people, &BaseItem.from_person/1), total, start_index)
    )
  end

  @doc """
  `GET /Persons/:name` — single person, looked up by name (not id).
  """
  def show(conn, %{"name" => name}) do
    case PeopleContext.get_person_by_name(name) do
      nil ->
        conn |> put_status(:not_found) |> json(%{"error" => "not_found"})

      person ->
        # Single person, so the counts a person page is built from are one
        # grouped query — the same payload ItemsController.show/2 returns for
        # the route jellyfin-web actually uses. Deliberately NOT done in
        # index/2, which builds up to 100 DTOs per request.
        json(conn, BaseItem.from_person(person, counts: PeopleContext.credit_counts(person.id)))
    end
  end

  defp parse_int(nil), do: nil
  defp parse_int(n) when is_integer(n), do: n

  defp parse_int(n) when is_binary(n) do
    case Integer.parse(n) do
      {i, _} -> i
      :error -> nil
    end
  end

  defp parse_int(_), do: nil
end
