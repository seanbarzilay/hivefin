defmodule Hivefin.Jellyfin.Params do
  @moduledoc """
  Shared numeric query-param clamping for paged Jellyfin list endpoints.

  Postgres raises (`LIMIT/OFFSET must not be negative`) rather than
  tolerating a negative value, so every paged query built from client input
  must clamp before it reaches Ecto's `limit/offset`. Lives here (not on a
  controller) so both a web controller and a context that builds the query
  directly can call the exact same function instead of each carrying its own
  copy that can drift out of sync.
  """

  @doc "Clamps a possibly-negative integer to 0. `nil` passes through unchanged."
  @spec clamp_non_neg(integer() | nil) :: non_neg_integer() | nil
  def clamp_non_neg(nil), do: nil
  def clamp_non_neg(n) when is_integer(n) and n < 0, do: 0
  def clamp_non_neg(n) when is_integer(n), do: n
end
