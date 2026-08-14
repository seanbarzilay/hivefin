defmodule HivefinWeb.Jellyfin.ItemsController do
  use HivefinWeb, :controller

  alias Hivefin.Jellyfin.Dto.BaseItem
  alias Hivefin.Jellyfin.Dto.UserData, as: UserDataDto
  alias Hivefin.Jellyfin.Params
  alias Hivefin.Library.{Item, Library, LibraryContext, PeopleContext, Person, UserData}

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
        include_item_types: ["Movie", "Episode"],
        recursive: true,
        limit: limit,
        start_index: 0,
        sort_by: "DateCreated",
        preload_media_sources: true
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
    opts =
      params
      |> browse_opts()
      # Always preload sources so BaseItem can attach MediaSources for play
      |> Keyword.put(:preload_media_sources, true)

    fields = opts[:fields] || []
    start_index = opts[:start_index] || 0

    # Modern SDK: GET /Items?ids=... (library page loads CollectionFolder this way)
    ids = parse_ids(params["Ids"] || params["ids"])

    {entries, total} =
      if ids != [] do
        entries = LibraryContext.get_items_by_ids(ids, preload_media_sources: true)
        {entries, length(entries)}
      else
        parent_id = blank_to_nil(params["ParentId"] || params["parentId"])
        LibraryContext.list_items_for_parent(parent_id, opts)
      end

    user_data_map = user_data_map_for(conn, entries)

    items =
      Enum.map(entries, fn
        %Library{} = library ->
          BaseItem.from_library(library)

        %Item{} = item ->
          BaseItem.from_item(item, fields: fields, user_data: user_data_for(item, user_data_map))

        %Person{} = person ->
          BaseItem.from_person(person)
      end)

    json(conn, BaseItem.query_result(items, total, start_index))
  end

  def show(conn, %{"item_id" => item_id} = params) do
    # Always preload sources for detail/playback readiness
    #
    # jellyfin-web 10.10.7 (the exact build this project bundles, see
    # Dockerfile) fetches the detail item via getItem(userId, itemId) — two
    # arguments, no Fields option at all. Upstream Jellyfin gets away with
    # that because UserLibraryController.GetItem builds a DtoOptions that
    # defaults Fields to AllItemFields: the detail route ignores the Fields
    # query param entirely and always returns everything, including People.
    # Force-appending "People" here matches that upstream behavior for THIS
    # route only. Do not "clean up" this inconsistency with
    # maybe_put_people/3's Fields gate in base_item.ex — that gate exists
    # specifically to keep a full cast list off every item in a 7k+ movie
    # listing page, and index/2, seasons/2, episodes/2, latest/2, and
    # resume/2 must keep relying on it.
    fields = Enum.uniq(["People" | parse_fields(params["Fields"] || params["fields"])])

    item = LibraryContext.get_item_with_sources(item_id)

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
            person_or_not_found(conn, item_id)
        end
    end
  end

  # A cast/crew click lands HERE, not on GET /Persons/{name}. Traced through
  # the bundled jellyfin-web 10.10.7 (Dockerfile pins jellyfin/jellyfin:10.10.7):
  # renderCast links via appRouter.getRouteUrl({Type: "Person", Id: person.Id}),
  # and "Person" is in that function's itemTypes list, so the href is
  # `#/details?id=<personId>`. itemDetails' getPromise then does
  # `if (params.id) return apiClient.getItem(userId, params.id)` — i.e.
  # GET /Users/{userId}/Items/{personId}, with NO Fields param. Its by-name
  # branches cover genre/musicgenre/musicartist only; apiClient.getPerson(name),
  # the one function that would call /Persons/{name}, has zero call sites in the
  # bundle. Without this branch every cast click 404s and the detail page spins
  # forever — loading.hide() only runs at the end of reloadFromItem, which the
  # rejected promise never reaches.
  #
  # Counts come along because the client's person page is built entirely from
  # them — see count_fields/1 in Dto.BaseItem. Single person, so a single
  # grouped count; never do this on a list path.
  defp person_or_not_found(conn, id) do
    case PeopleContext.get_person(id) do
      %Person{} = person ->
        json(conn, BaseItem.from_person(person, counts: PeopleContext.credit_counts(person.id)))

      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{"error" => "not_found"})
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
  `GET /Items/:item_id/Similar` — empty stub (item detail page requests this).
  """
  def similar(conn, params) do
    start_index = clamp_non_neg(parse_int(params["StartIndex"] || params["startIndex"])) || 0
    json(conn, BaseItem.query_result([], 0, start_index))
  end

  @doc """
  `GET /Items/Suggestions` — must not fall through to `/Items/:item_id`
  (that 400s because "Suggestions" is not a UUID). Empty QueryResult.
  """
  def suggestions(conn, params) do
    start_index = clamp_non_neg(parse_int(params["StartIndex"] || params["startIndex"])) || 0
    json(conn, BaseItem.query_result([], 0, start_index))
  end

  @doc """
  `GET /Movies/Recommendations` — RecommendationDto[]. HTML here crashes
  kotlinx on the Movies library Recommended tab.
  """
  def movie_recommendations(conn, _params) do
    json(conn, [])
  end

  @doc """
  `GET /Genres` — QueryResult of genre folders. Empty until we store genres.
  """
  def genres(conn, params) do
    start_index = clamp_non_neg(parse_int(params["StartIndex"] || params["startIndex"])) || 0
    json(conn, BaseItem.query_result([], 0, start_index))
  end

  @doc """
  `GET /Items/:item_id/Intros` and `GET /Users/:user_id/Items/:item_id/Intros`.

  jellyfin-web always requests intros before PlaybackInfo. A 404 aborts play with
  "Unable to find a valid media source to play." Empty list = no preroll.
  """
  def intros(conn, _params) do
    json(conn, BaseItem.query_result([], 0, 0))
  end

  @doc """
  `GET /Items/:item_id/ThemeMedia` — theme songs/videos (empty is fine).
  """
  def theme_media(conn, %{"item_id" => item_id}) do
    empty = BaseItem.query_result([], 0, 0)

    json(conn, %{
      "ThemeVideosResult" => Map.put(empty, "OwnerId", item_id),
      "ThemeSongsResult" => Map.put(empty, "OwnerId", item_id),
      "SoundtrackSongsResult" => Map.put(empty, "OwnerId", item_id)
    })
  end

  @doc """
  `GET /Items/:item_id/ThemeSongs` — ThemeMediaResult. Wholphin plays theme
  music from this; a 404 body is not a ThemeMediaResult and kotlinx throws.
  """
  def theme_songs(conn, %{"item_id" => item_id}) do
    json(conn, Map.put(BaseItem.query_result([], 0, 0), "OwnerId", item_id))
  end

  @doc """
  `GET /Items/:item_id/ThemeVideos` — same empty ThemeMediaResult shape.
  """
  def theme_videos(conn, %{"item_id" => item_id}) do
    json(conn, Map.put(BaseItem.query_result([], 0, 0), "OwnerId", item_id))
  end

  @doc """
  `GET /Items/:item_id/SpecialFeatures` (and User/UserItems aliases).

  Official Jellyfin returns a raw BaseItemDto **array**, not a QueryResult.
  """
  def special_features(conn, _params) do
    json(conn, [])
  end

  @doc """
  `GET /Items/:item_id/LocalTrailers` — raw BaseItemDto array.
  """
  def local_trailers(conn, _params) do
    json(conn, [])
  end

  @doc """
  `GET /MediaSegments/:item_id` — intro/credit markers. Empty QueryResult.
  """
  def media_segments(conn, _params) do
    json(conn, BaseItem.query_result([], 0, 0))
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
      preload_media_sources: "MediaSources" in fields,
      preload_people: "People" in fields,
      person_ids: parse_ids(params["PersonIds"] || params["personIds"])
    ]
  end

  defdelegate clamp_non_neg(n), to: Params

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

  defp parse_ids(nil), do: []
  defp parse_ids(""), do: []

  defp parse_ids(ids) when is_binary(ids) do
    ids
    |> String.split([",", "|"], trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_ids(ids) when is_list(ids), do: Enum.map(ids, &to_string/1)
  defp parse_ids(_), do: []

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(v), do: v

  defp authorized_user?(conn, user_id) do
    case conn.assigns[:current_user] do
      %{id: id} ->
        Hivefin.Jellyfin.Id.coerce(id) == Hivefin.Jellyfin.Id.coerce(user_id)

      _ ->
        false
    end
  end
end
