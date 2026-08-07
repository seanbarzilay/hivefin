defmodule Hivefin.Jellyfin.Dto.SdkRequired do
  @moduledoc """
  Fills in the `MediaSourceInfo` / `MediaStream` fields that strictly-typed
  Jellyfin clients require to be present.

  jellyfin-sdk-kotlin (used by the official Android app) generates these models
  with kotlinx.serialization. A property declared with **no default value** is
  required: if the key is absent, `decodeFromString` raises
  `MissingFieldException`, the client discards the whole `MediaSourceInfo`, and
  playback silently never starts — the app shows an empty player at 00:00 with
  no stream request in the server log.

  The SDK's `Json` config (`ApiSerializer`) sets `ignoreUnknownKeys = true`,
  `explicitNulls = false` and `coerceInputValues = true`. Those tolerate *extra*
  keys and null-for-defaulted values, but none of them rescue a **missing**
  property that has no default — hence this module.

  jellyfin-web is JavaScript and ignores absent keys entirely, which is why the
  browser could play a title while the Android app hung on the same response.

  Defaults are merged *under* the caller's map, so real values always win and
  dropping nil keys can never remove a required one.

  Field sets mirror `jellyfin-model/.../api/{MediaSourceInfo,MediaStream}.kt`.
  """

  @source %{
    "Protocol" => "File",
    "Type" => "Default",
    "IsRemote" => false,
    "ReadAtNativeFramerate" => false,
    "IgnoreDts" => false,
    "IgnoreIndex" => false,
    "GenPtsInput" => false,
    "SupportsTranscoding" => true,
    "SupportsDirectStream" => false,
    "SupportsDirectPlay" => false,
    "IsInfiniteStream" => false,
    "RequiresOpening" => false,
    "RequiresClosing" => false,
    "RequiresLooping" => false,
    "SupportsProbing" => true,
    # Non-null MediaStreamProtocol enum: "http" for direct play, "hls" for HLS.
    # nil is not representable client-side, so it can never be omitted.
    "TranscodingSubProtocol" => "http",
    "HasSegments" => false
  }

  @stream %{
    "IsInterlaced" => false,
    "IsDefault" => false,
    "IsForced" => false,
    "IsHearingImpaired" => false,
    "IsOriginal" => false,
    "IsExternal" => false,
    "IsTextSubtitleStream" => false,
    "SupportsExternalStream" => false
  }

  @doc "Drops nil values from a MediaSourceInfo map, then fills required fields."
  def source(map) when is_map(map), do: Map.merge(@source, drop_nils(map))

  @doc "Drops nil values from a MediaStream map, then fills required fields."
  def stream(map) when is_map(map), do: Map.merge(@stream, drop_nils(map))

  @doc "Required MediaSourceInfo keys (for tests)."
  def source_keys, do: Map.keys(@source)

  @doc "Required MediaStream keys (for tests)."
  def stream_keys, do: Map.keys(@stream)

  defp drop_nils(map) do
    map
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end
end
