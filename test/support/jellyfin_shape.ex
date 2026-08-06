defmodule Hivefin.JellyfinShape do
  @moduledoc """
  Loads Jellyfin fixture JSON and asserts response shape contracts
  (required keys + types). Used by `test/hivefin_web/compat/*`.
  """

  import ExUnit.Assertions

  @fixtures_root Path.expand("fixtures/jellyfin", __DIR__)

  @type type_spec ::
          :string
          | :integer
          | :number
          | :boolean
          | :list
          | :map
          | :any
          | {:list, type_spec()}
          | %{optional(String.t()) => type_spec()}

  @doc """
  Loads a fixture JSON map.

  ## Examples

      load_fixture("web", "views")
      load_fixture(:androidtv, "playback_info")
  """
  def load_fixture(client, name) when is_binary(name) do
    client = to_string(client)
    path = Path.join([@fixtures_root, client, "#{name}.json"])

    unless File.exists?(path) do
      flunk("missing fixture: #{path}")
    end

    path
    |> File.read!()
    |> Jason.decode!()
  end

  @doc """
  Infers a type spec map from a sample (fixture) value tree.
  """
  def shape_from_sample(sample) when is_map(sample) do
    Map.new(sample, fn {key, value} -> {key, type_of(value)} end)
  end

  @doc """
  Asserts `actual` has every key in `expected_types` with a matching type.

  Nested maps recurse. Lists use `{:list, inner}` and check each element when
  non-empty. Does not require exact value equality.
  """
  def assert_shape(actual, expected_types) when is_map(actual) and is_map(expected_types) do
    Enum.each(expected_types, fn {key, type} ->
      assert Map.has_key?(actual, key), "missing #{key}"
      assert type_match?(Map.get(actual, key), type),
             "bad type for #{key}: expected #{inspect(type)}, got #{inspect(Map.get(actual, key))}"
    end)

    actual
  end

  def assert_shape(actual, _expected_types) do
    flunk("assert_shape expected a map, got: #{inspect(actual)}")
  end

  @doc false
  def type_of(value) when is_binary(value), do: :string
  def type_of(value) when is_integer(value), do: :integer
  def type_of(value) when is_float(value), do: :number
  def type_of(value) when is_boolean(value), do: :boolean
  def type_of(nil), do: :any

  def type_of(value) when is_list(value) do
    case value do
      [] ->
        :list

      # Heterogeneous maps (e.g. Video + Audio MediaStreams): require only common keys.
      [head | _rest] = list when is_map(head) ->
        if Enum.all?(list, &is_map/1) do
          {:list, common_map_shape(list)}
        else
          {:list, type_of(head)}
        end

      [head | _] ->
        {:list, type_of(head)}
    end
  end

  def type_of(value) when is_map(value), do: shape_from_sample(value)

  defp common_map_shape(maps) do
    shapes = Enum.map(maps, &shape_from_sample/1)

    common_keys =
      shapes
      |> Enum.map(&MapSet.new(Map.keys(&1)))
      |> Enum.reduce(&MapSet.intersection/2)

    Map.new(common_keys, fn key ->
      types = shapes |> Enum.map(&Map.fetch!(&1, key)) |> Enum.uniq()
      type = if match?([_], types), do: hd(types), else: :any
      {key, type}
    end)
  end

  @doc false
  def type_match?(_value, :any), do: true
  def type_match?(value, :string) when is_binary(value), do: true
  def type_match?(value, :integer) when is_integer(value), do: true
  def type_match?(value, :number) when is_number(value), do: true
  def type_match?(value, :boolean) when is_boolean(value), do: true
  def type_match?(value, :list) when is_list(value), do: true
  def type_match?(value, :map) when is_map(value), do: true

  # Fixture integers often stand in for numeric fields (e.g. PlayedPercentage: 0).
  def type_match?(value, :integer) when is_float(value), do: true

  def type_match?(value, {:list, _inner}) when is_list(value) and value == [], do: true

  def type_match?(value, {:list, inner}) when is_list(value) do
    Enum.all?(value, &type_match?(&1, inner))
  end

  def type_match?(value, expected) when is_map(value) and is_map(expected) do
    Enum.all?(expected, fn {key, type} ->
      Map.has_key?(value, key) and type_match?(Map.get(value, key), type)
    end)
  end

  def type_match?(_value, _type), do: false
end
