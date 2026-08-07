defmodule Hivefin.Jellyfin.Id do
  @moduledoc """
  Jellyfin client ID formatting.

  jellyfin-vue's router `validateGuard` only accepts item/library ids matching
  `/[0-9a-f]{32}/i` (32 consecutive hex chars). Standard UUID strings with
  dashes fail that check, so navigating to `/item/{uuid}` or `/library/{uuid}`
  after playback looks like a "non-existing page".

  We advertise ids without dashes in API JSON and accept both formats on input.
  """

  @doc """
  Format a stored UUID for JSON responses (no dashes, lowercase).
  """
  @spec format(String.t() | nil) :: String.t() | nil
  def format(nil), do: nil

  def format(id) when is_binary(id) do
    id |> String.replace("-", "") |> String.downcase()
  end

  def format(id), do: id

  @doc """
  Normalize a client-supplied id to dashed UUID form for DB lookups.

  Accepts:
  - `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`
  - `xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx` (32 hex)
  """
  @spec normalize(String.t() | nil) :: {:ok, String.t()} | :error
  def normalize(nil), do: :error
  def normalize(""), do: :error

  def normalize(id) when is_binary(id) do
    hex =
      id
      |> String.trim()
      |> String.replace("-", "")
      |> String.downcase()

    if byte_size(hex) == 32 and Regex.match?(~r/^[0-9a-f]{32}$/, hex) do
      <<a::binary-size(8), b::binary-size(4), c::binary-size(4), d::binary-size(4),
        e::binary-size(12)>> = hex

      {:ok, "#{a}-#{b}-#{c}-#{d}-#{e}"}
    else
      :error
    end
  end

  def normalize(_), do: :error

  @doc """
  Like `normalize/1` but returns the original string when already dashed-looking
  or when normalization fails (best-effort for non-UUID keys).
  """
  @spec coerce(String.t() | nil) :: String.t() | nil
  def coerce(nil), do: nil

  def coerce(id) when is_binary(id) do
    case normalize(id) do
      {:ok, dashed} -> dashed
      :error -> id
    end
  end
end
