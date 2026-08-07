defmodule HivefinWeb.Jellyfin.ItemsController do
  use HivefinWeb, :controller

  alias Hivefin.Jellyfin.Dto.BaseItem
  alias Hivefin.Jellyfin.Dto.UserData, as: UserDataDto
  alias Hivefin.Library.{Item, Library, LibraryContext, UserData}

  def views(conn, _params) do
    libraries = LibraryContext.list_libraries()
    items = Enum.map(libraries, &BaseItem.from_library/1)

    json(conn, BaseItem.query_result(items, length(items)))
  end

  @doc """
  Modern SDK path: `GET /UserViews` (jellyfin-vue fetchIndexPage).
  Same payload as `GET /Users/:id/Views`.
  """
  def user_views(conn, params), do: views(conn, params)

  @doc """
  Modern SDK path: `GET /Items/Latest` — returns a JSON **array** of BaseItemDto
  (not a QueryResult). Used after login by jellyfin-vue.
  """
  def latest(conn, params) do
    user = conn.assigns.current_user
    parent_id = blank_to_nil(params["ParentId"] || params["parentId"])
    limit = clamp_non_neg(parse_int(params["Limit"] || params["limit"])) || 16
    fields = parse_fields(params["Fields"] || params["fields"])

    {entries, _total} =
      LibraryContext.list_items_for_parent(parent_id,
        include_item_types: ["Movie", "Episode", "Series"],
        recursive: true,
        limit: limit,
        start_index: 0,
        sort_by: "DateCreated"
      )

    user_data_map = user_data_map_for(conn, entries)

    items =
      Enum.map(entries, fn
        %Item{} = item ->
          BaseItem.from_item(item, fields: fields, user_data: user_data_for(item, user_data_map))

        %Library{} = library ->
          BaseItem.from_library(library)
      end)

    # SDK expects a bare array, not {Items, TotalRecordCount}
    _ = user
    json(conn, items)
  end

  @doc """
  Modern SDK path: `GET /UserItems/Resume` (same as Users/:id/Items/Resume).
  """
  def user_items_resume(conn, params) do
    user_id = conn.assigns.current_user.id
    resume(conn, Map.put(params, "user_id", user_id))
  end


  def index(conn, params) do
    parent_id = blank_to_nil(params["ParentId"] || params["parentId"])
    opts = browse_opts(params)
    {entries, total} = LibraryContext.list_items_for_parent(parent_id, opts)
    fields = opts[:fields] || []
    user_data_map = user_data_map_for(conn, entries)

    items =
      Enum.map(entries, fn
        %Library{} = library ->
          BaseItem.from_library(library)

        %Item{} = item ->
          BaseItem.from_item(item, fields: fields, user_data: user_data_for(item, user_data_map))
      end)

    start_index = opts[:start_index] || 0
    json(conn, BaseItem.query_result(items, total, start_index))
  end

  def show(conn, %{"item_id" => item_id} = params) do
    fields = parse_fields(params["Fields"] || params["fields"])
    preload? = "MediaSources" in fields

    item =
      if preload? do
        LibraryContext.get_item_with_sources(item_id)
      else
        LibraryContext.get_item(item_id)
      end

    case item do
      %Item{} = item ->
        user_data = load_user_data(conn, item.id)
        json(conn, BaseItem.from_item(item, fields: fields, user_data: user_data))

      nil ->
        # Libraries can also be opened as items (view folders)
        case LibraryContext.get_library(item_id) do
          %Library{} = library ->
            json(conn, BaseItem.from_library(library))

          nil ->
            conn
            |> put_status(:not_found)
            |> json(%{"error" => "not_found"})
        end
    end
  end

  @doc """
  `GET /Users/:user_id/Items/Resume` — in-progress items for continue watching.
  """
  def resume(conn, %{"user_id" => user_id} = params) do
    if authorized_user?(conn, user_id) do
      opts = [
        limit: clamp_non_neg(parse_int(params["Limit"] || params["limit"])) || 50,
        start_index: clamp_non_neg(parse_int(params["StartIndex"] || params["startIndex"])) || 0
      ]

      fields = parse_fields(params["Fields"] || params["fields"])
      {rows, total} = UserData.list_resume(user_id, opts)

      items =
        rows
        |> Enum.filter(fn ud -> match?(%Item{}, ud.item) end)
        |> Enum.map(fn ud ->
          BaseItem.from_item(ud.item,
            fields: fields,
            user_data: UserDataDto.from_user_data(ud)
          )
        end)

      start_index = opts[:start_index] || 0
      json(conn, BaseItem.query_result(items, total, start_index))
    else
      conn
      |> put_status(:forbidden)
      |> json(%{"error" => "forbidden"})
    end
  end

  @doc """
  `GET /Shows/NextUp` — next-up episodes (empty stub until series progress logic).
  """
  def next_up(conn, params) do
    start_index = clamp_non_neg(parse_int(params["StartIndex"] || params["startIndex"])) || 0
    json(conn, BaseItem.query_result([], 0, start_index))
  end

  @doc """
  Jellyfin `GET /Shows/:series_id/Seasons` — seasons under a series.
  """
  def seasons(conn, %{"series_id" => series_id} = params) do
    opts =
      browse_opts(params)
      |> Keyword.put(:include_item_types, ["Season"])
      |> Keyword.put(:recursive, false)

    {entries, total} = LibraryContext.list_items_for_parent(series_id, opts)
    fields = opts[:fields] || []
    user_data_map = user_data_map_for(conn, entries)

    items =
      Enum.map(entries, fn item ->
        BaseItem.from_item(item, fields: fields, user_data: user_data_for(item, user_data_map))
      end)

    start_index = opts[:start_index] || 0
    json(conn, BaseItem.query_result(items, total, start_index))
  end

  @doc """
  Jellyfin `GET /Shows/:series_id/Episodes` — episodes under a series.
  """
  def episodes(conn, %{"series_id" => series_id} = params) do
    opts = browse_opts(params)
    fields = opts[:fields] || []
    start_index = opts[:start_index] || 0

    case LibraryContext.get_item(series_id) do
      %Item{type: :series} = series ->
        {entries, total} = LibraryContext.list_episodes_for_series(series, opts)
        user_data_map = user_data_map_for(conn, entries)

        items =
          Enum.map(entries, fn item ->
            BaseItem.from_item(item,
              fields: fields,
              user_data: user_data_for(item, user_data_map)
            )
          end)

        json(conn, BaseItem.query_result(items, total, start_index))

      _ ->
        json(conn, BaseItem.query_result([], 0, start_index))
    end
  end

  defp user_data_map_for(conn, entries) do
    user = conn.assigns[:current_user]
    item_ids = for %Item{id: id} <- entries, do: id

    if user && item_ids != [] do
      UserData.map_for_items(user.id, item_ids)
    else
      %{}
    end
  end

  defp user_data_for(%Item{id: id}, map) do
    UserDataDto.from_user_data(Map.get(map, id))
  end

  defp load_user_data(conn, item_id) do
    case conn.assigns[:current_user] do
      %{id: user_id} -> UserDataDto.from_user_data(UserData.get(user_id, item_id))
      _ -> UserDataDto.default()
    end
  end

  defp browse_opts(params) do
    fields = parse_fields(params["Fields"] || params["fields"])

    [
      include_item_types:
        parse_include_types(params["IncludeItemTypes"] || params["includeItemTypes"]),
      recursive: params["Recursive"] || params["recursive"],
      limit: clamp_non_neg(parse_int(params["Limit"] || params["limit"])),
      start_index: clamp_non_neg(parse_int(params["StartIndex"] || params["startIndex"])) || 0,
      sort_by: params["SortBy"] || params["sortBy"],
      fields: fields,
      preload_media_sources: "MediaSources" in fields
    ]
  end

  defp clamp_non_neg(nil), do: nil
  defp clamp_non_neg(n) when is_integer(n) and n < 0, do: 0
  defp clamp_non_neg(n) when is_integer(n), do: n

  defp parse_include_types(nil), do: nil
  defp parse_include_types(""), do: nil

  defp parse_include_types(types) when is_binary(types) do
    types
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
  end

  defp parse_include_types(types) when is_list(types), do: types
  defp parse_include_types(_), do: nil

  defp parse_fields(nil), do: []
  defp parse_fields(""), do: []

  defp parse_fields(fields) when is_binary(fields) do
    fields
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
  end

  defp parse_fields(fields) when is_list(fields), do: Enum.map(fields, &to_string/1)
  defp parse_fields(_), do: []

  defp parse_int(nil), do: nil
  defp parse_int(n) when is_integer(n), do: n

  defp parse_int(n) when is_binary(n) do
    case Integer.parse(n) do
      {i, _} -> i
      :error -> nil
    end
  end

  defp parse_int(_), do: nil

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(v), do: v

  defp authorized_user?(conn, user_id) do
    case conn.assigns[:current_user] do
      %{id: ^user_id} -> true
      _ -> false
    end
  end
end
