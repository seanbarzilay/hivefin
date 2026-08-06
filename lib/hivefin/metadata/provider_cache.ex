defmodule Hivefin.Metadata.ProviderCache do
  @moduledoc """
  Optional Postgres cache for external provider payloads (e.g. TMDB search).
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias Hivefin.Repo

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "provider_cache" do
    field :provider, :string
    field :cache_key, :string
    field :payload, :map, default: %{}
    field :expires_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [:provider, :cache_key, :payload, :expires_at])
    |> validate_required([:provider, :cache_key, :payload])
    |> unique_constraint([:provider, :cache_key])
  end

  @doc """
  Returns cached payload when present and not expired.
  """
  def get(provider, cache_key) when is_binary(provider) and is_binary(cache_key) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    from(c in __MODULE__,
      where: c.provider == ^provider and c.cache_key == ^cache_key,
      where: is_nil(c.expires_at) or c.expires_at > ^now
    )
    |> Repo.one()
    |> case do
      %__MODULE__{payload: payload} -> {:ok, payload}
      nil -> :miss
    end
  end

  @doc """
  Upserts a cache entry. `ttl_seconds` defaults to 24 hours.
  """
  def put(provider, cache_key, payload, opts \\ [])
      when is_binary(provider) and is_binary(cache_key) and is_map(payload) do
    ttl = Keyword.get(opts, :ttl_seconds, 86_400)
    expires_at = DateTime.add(DateTime.utc_now(), ttl, :second) |> DateTime.truncate(:microsecond)

    attrs = %{
      provider: provider,
      cache_key: cache_key,
      payload: payload,
      expires_at: expires_at
    }

    case Repo.get_by(__MODULE__, provider: provider, cache_key: cache_key) do
      nil ->
        %__MODULE__{}
        |> changeset(attrs)
        |> Repo.insert()

      existing ->
        existing
        |> changeset(attrs)
        |> Repo.update()
    end
  end
end
