defmodule Hivefin.Settings do
  @moduledoc """
  Persistent operator settings (admin console).

  Values are stored in the `settings` table and applied into
  `Application` env so runtime readers (TMDB, SystemInfo) pick them up.
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias Hivefin.Repo

  @primary_key {:key, :string, autogenerate: false}
  schema "settings" do
    field :value, :string
    timestamps(type: :utc_datetime_usec)
  end

  @known_keys ~w(tmdb_api_key server_name tmdb_rate_limit_per_sec)

  def known_keys, do: @known_keys

  def changeset(setting, attrs) do
    setting
    |> cast(attrs, [:key, :value])
    |> validate_required([:key, :value])
    |> validate_inclusion(:key, @known_keys)
  end

  def get(key) when is_binary(key) do
    case Repo.get(__MODULE__, key) do
      %__MODULE__{value: value} -> value
      nil -> nil
    end
  end

  def get(key, default) when is_binary(key) do
    get(key) || default
  end

  def put(key, value) when is_binary(key) and is_binary(value) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    row = %{
      key: key,
      value: value,
      inserted_at: now,
      updated_at: now
    }

    case Repo.insert_all(__MODULE__, [row],
           on_conflict: {:replace, [:value, :updated_at]},
           conflict_target: [:key],
           returning: true
         ) do
      {1, [setting]} ->
        apply_key!(key, value)
        {:ok, setting}

      _ ->
        {:error, :upsert_failed}
    end
  end

  def put(key, value) when is_binary(key) and is_integer(value) do
    put(key, Integer.to_string(value))
  end

  def delete(key) when is_binary(key) do
    case Repo.get(__MODULE__, key) do
      nil ->
        :ok

      setting ->
        {:ok, _} = Repo.delete(setting)
        clear_key!(key)
        :ok
    end
  end

  def all do
    from(s in __MODULE__, order_by: [asc: s.key])
    |> Repo.all()
    |> Map.new(&{&1.key, &1.value})
  end

  @doc """
  Loads DB settings into Application env (call after Repo is up).
  """
  def apply_all! do
    Enum.each(all(), fn {key, value} -> apply_key!(key, value) end)
    :ok
  end

  @doc """
  Snapshot for the admin settings form (masks secrets for display).
  """
  def admin_snapshot do
    stored = all()
    env_key = Application.get_env(:hivefin, :tmdb_api_key)

    effective_key =
      case stored["tmdb_api_key"] do
        k when is_binary(k) and k != "" -> k
        _ -> env_key
      end

    %{
      server_name:
        stored["server_name"] || Application.get_env(:hivefin, :server_name, "Hivefin"),
      tmdb_api_key_set: is_binary(effective_key) and effective_key != "",
      tmdb_api_key_source:
        cond do
          is_binary(stored["tmdb_api_key"]) and stored["tmdb_api_key"] != "" -> :database
          is_binary(env_key) and env_key != "" -> :env
          true -> :none
        end,
      tmdb_api_key_hint: mask_secret(effective_key),
      tmdb_rate_limit_per_sec:
        parse_positive_int(stored["tmdb_rate_limit_per_sec"]) ||
          Application.get_env(:hivefin, :tmdb_rate_limit_per_sec, 4),
      tmdb_base_url: Application.get_env(:hivefin, :tmdb_base_url, "https://api.themoviedb.org/3")
    }
  end

  defp apply_key!("tmdb_api_key", value) do
    Application.put_env(:hivefin, :tmdb_api_key, blank_to_nil(value))
  end

  defp apply_key!("server_name", value) do
    Application.put_env(:hivefin, :server_name, value)
  end

  defp apply_key!("tmdb_rate_limit_per_sec", value) do
    case parse_positive_int(value) do
      n when is_integer(n) ->
        Application.put_env(:hivefin, :tmdb_rate_limit_per_sec, n)
        # Best-effort live update of the running limiter
        _ = Hivefin.Metadata.RateLimiter.set_rate(n)
        :ok

      _ ->
        :ok
    end
  end

  defp apply_key!(_, _), do: :ok

  defp clear_key!("tmdb_api_key") do
    # Fall back to env var if present
    case System.get_env("HIVEFIN_TMDB_API_KEY") do
      k when is_binary(k) and k != "" -> Application.put_env(:hivefin, :tmdb_api_key, k)
      _ -> Application.put_env(:hivefin, :tmdb_api_key, nil)
    end
  end

  defp clear_key!("server_name") do
    Application.put_env(:hivefin, :server_name, "Hivefin")
  end

  defp clear_key!("tmdb_rate_limit_per_sec") do
    Application.put_env(:hivefin, :tmdb_rate_limit_per_sec, 4)
  end

  defp clear_key!(_), do: :ok

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(v), do: v

  defp parse_positive_int(nil), do: nil
  defp parse_positive_int(n) when is_integer(n) and n > 0, do: n

  defp parse_positive_int(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, _} when n > 0 -> n
      _ -> nil
    end
  end

  defp parse_positive_int(_), do: nil

  defp mask_secret(nil), do: nil
  defp mask_secret(""), do: nil

  defp mask_secret(key) when is_binary(key) do
    len = String.length(key)

    if len <= 8 do
      String.duplicate("•", min(len, 6))
    else
      String.slice(key, 0, 3) <> String.duplicate("•", 8) <> String.slice(key, -3, 3)
    end
  end
end
