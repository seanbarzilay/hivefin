defmodule HivefinWeb.JellyfinSocket do
  @moduledoc """
  Jellyfin WebSocket protocol handler.

  Clients open `/socket`, expect a `ForceKeepAlive` on connect, and then send
  `KeepAlive` on that interval. Message dispatch is an explicit allowlist:
  `MessageType` is untrusted client input.
  """

  @behaviour WebSock

  require Logger

  alias Hivefin.Jellyfin.WsMessage

  # Advertised keepalive window, in seconds.
  @keep_alive_seconds 60

  # Accepted but inert: hivefin has no activity log or task scheduler.
  @noop_types ~w(
    ActivityLogEntryStart ActivityLogEntryStop
    ScheduledTasksInfoStart ScheduledTasksInfoStop
  )

  @impl WebSock
  def init(state) do
    {:push, {:text, WsMessage.force_keep_alive(@keep_alive_seconds)}, state}
  end

  @impl WebSock
  def handle_in({text, [opcode: :text]}, state) do
    case Jason.decode(text) do
      {:ok, %{"MessageType" => type}} when is_binary(type) ->
        dispatch(type, state)

      {:ok, _other} ->
        Logger.debug("jellyfin socket: message without MessageType")
        {:ok, state}

      {:error, _} ->
        Logger.debug("jellyfin socket: malformed JSON frame")
        {:ok, state}
    end
  end

  # Jellyfin's protocol is text-only.
  def handle_in({_data, [opcode: _other]}, state), do: {:ok, state}

  @impl WebSock
  def handle_info(_message, state), do: {:ok, state}

  @impl WebSock
  def terminate(_reason, _state), do: :ok

  defp dispatch("KeepAlive", state), do: {:push, {:text, WsMessage.keep_alive()}, state}

  defp dispatch(type, state) when type in @noop_types, do: {:ok, state}

  defp dispatch(type, state) do
    Logger.debug("jellyfin socket: unhandled MessageType #{inspect(type)}")
    {:ok, state}
  end
end
