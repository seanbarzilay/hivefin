defmodule Hivefin.Jellyfin.WsMessage do
  @moduledoc """
  Builds Jellyfin WebSocket message envelopes.

  Server→client messages (`OutboundWebSocketMessage` in jellyfin-sdk-kotlin)
  declare `MessageId` with no default, so kotlinx.serialization treats it as
  required: omit it and the client raises `MissingFieldException` and discards
  the message without a visible error.
  """

  @doc "Builds an envelope. `Data` is omitted entirely when `data` is nil."
  def build(type, data \\ nil) when is_binary(type) do
    base = %{"MessageType" => type, "MessageId" => Ecto.UUID.generate()}

    if is_nil(data), do: base, else: Map.put(base, "Data", data)
  end

  @doc "JSON-encoded `build/2`."
  def encode(type, data \\ nil), do: type |> build(data) |> Jason.encode!()

  @doc "ForceKeepAlive. `Data` is the keepalive window in seconds (required Int)."
  def force_keep_alive(seconds) when is_integer(seconds),
    do: encode("ForceKeepAlive", seconds)

  @doc "KeepAlive reply to a client KeepAlive."
  def keep_alive, do: encode("KeepAlive")
end
