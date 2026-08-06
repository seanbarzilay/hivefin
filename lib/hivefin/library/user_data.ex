defmodule Hivefin.Library.UserData do
  @moduledoc """
  Per-user item playback state (resume position, played flag, etc.).

  Jellyfin ticks: `1 second = 10_000_000` ticks.
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias Hivefin.Repo

  @ticks_per_second 10_000_000

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "user_data" do
    field :playback_position_ticks, :integer, default: 0
    field :played_percentage, :float, default: 0.0
    field :played, :boolean, default: false
    field :play_count, :integer, default: 0
    field :is_favorite, :boolean, default: false
    field :last_played_date, :utc_datetime_usec

    belongs_to :user, Hivefin.Accounts.User
    belongs_to :item, Hivefin.Library.Item

    timestamps(type: :utc_datetime_usec)
  end

  def ticks_per_second, do: @ticks_per_second

  def seconds_to_ticks(seconds) when is_number(seconds) do
    trunc(seconds * @ticks_per_second)
  end

  def ticks_to_seconds(ticks) when is_integer(ticks) do
    ticks / @ticks_per_second
  end

  def changeset(user_data, attrs) do
    user_data
    |> cast(attrs, [
      :playback_position_ticks,
      :played_percentage,
      :played,
      :play_count,
      :is_favorite,
      :last_played_date,
      :user_id,
      :item_id
    ])
    |> validate_required([:user_id, :item_id])
    |> validate_number(:playback_position_ticks, greater_than_or_equal_to: 0)
    |> validate_number(:played_percentage,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 100
    )
    |> validate_number(:play_count, greater_than_or_equal_to: 0)
    |> unique_constraint([:user_id, :item_id])
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:item_id)
  end

  @doc """
  Inserts or updates UserData for a user/item pair.

  attrs: `:playback_position_ticks`, `:played_percentage`, `:played`,
  `:last_played_date`, `:play_count`, `:is_favorite`.
  """
  def upsert(user_id, item_id, attrs)
      when is_binary(user_id) and is_binary(item_id) and is_map(attrs) do
    attrs =
      attrs
      |> normalize_attrs()
      |> maybe_default_last_played_date()

    case get(user_id, item_id) do
      nil ->
        %__MODULE__{}
        |> changeset(Map.merge(attrs, %{user_id: user_id, item_id: item_id}))
        |> Repo.insert()

      %__MODULE__{} = existing ->
        existing
        |> changeset(attrs)
        |> Repo.update()
    end
  end

  def get(user_id, item_id) when is_binary(user_id) and is_binary(item_id) do
    Repo.get_by(__MODULE__, user_id: user_id, item_id: item_id)
  end

  def get(_, _), do: nil

  @doc """
  Returns a map of `item_id => %UserData{}` for the given user and item ids.
  """
  def map_for_items(user_id, item_ids)
      when is_binary(user_id) and is_list(item_ids) do
    item_ids = Enum.filter(item_ids, &is_binary/1)

    if item_ids == [] do
      %{}
    else
      from(ud in __MODULE__, where: ud.user_id == ^user_id and ud.item_id in ^item_ids)
      |> Repo.all()
      |> Map.new(&{&1.item_id, &1})
    end
  end

  @allowed_attr_keys [
    :playback_position_ticks,
    :played_percentage,
    :played,
    :play_count,
    :is_favorite,
    :last_played_date
  ]

  @string_key_map %{
    "playback_position_ticks" => :playback_position_ticks,
    "played_percentage" => :played_percentage,
    "played" => :played,
    "play_count" => :play_count,
    "is_favorite" => :is_favorite,
    "last_played_date" => :last_played_date
  }

  defp normalize_attrs(attrs) do
    attrs
    |> Map.new(fn
      {k, v} when is_atom(k) ->
        {k, v}

      {k, v} when is_binary(k) ->
        {Map.get(@string_key_map, k), v}
    end)
    |> Map.delete(nil)
    |> Map.take(@allowed_attr_keys)
  end

  defp maybe_default_last_played_date(attrs) do
    if Map.has_key?(attrs, :last_played_date) do
      attrs
    else
      Map.put(attrs, :last_played_date, DateTime.utc_now() |> DateTime.truncate(:microsecond))
    end
  end
end
