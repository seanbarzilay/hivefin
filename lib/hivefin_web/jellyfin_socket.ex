defmodule HivefinWeb.JellyfinSocket do
  @moduledoc """
  Jellyfin WebSocket protocol handler.

  Clients open `/socket`, expect a `ForceKeepAlive` on connect, and then send
  `KeepAlive` on that interval. Message dispatch is an explicit allowlist:
  `MessageType` is untrusted client input.
  """

  @behaviour WebSock

  require Logger

  alias Hivefin.Jellyfin.Dto.Session, as: SessionDto
  alias Hivefin.Jellyfin.WsMessage
  alias Hivefin.Sessions

  # Advertised keepalive window, in seconds.
  @keep_alive_seconds 60

  # Accepted but inert: hivefin has no activity log or task scheduler.
  @noop_types ~w(
    ActivityLogEntryStart ActivityLogEntryStop
    ScheduledTasksInfoStart ScheduledTasksInfoStop
  )

  @impl WebSock
  def init(state) do
    :ok =
      Sessions.register(state.session_id, %{
        user_id: state.user_id,
        device_id: state.device_id
      })

    :ok = Sessions.subscribe()
    Sessions.broadcast_changed()

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
  def handle_info({:jellyfin_push, message}, state) do
    {:push, {:text, Jason.encode!(message)}, state}
  end

  def handle_info(:sessions_changed, state) do
    if MapSet.member?(state.subscriptions, "Sessions") do
      {:push, {:text, sessions_message(state)}, state}
    else
      {:ok, state}
    end
  end

  def handle_info({:jellyfin_session_state, attrs}, state) do
    # Registry entries are caller-owned, so the socket applies its own update.
    Sessions.update(state.session_id, attrs)
    Sessions.broadcast_changed()
    {:ok, state}
  end

  def handle_info(_message, state), do: {:ok, state}

  @impl WebSock
  def terminate(_reason, _state) do
    # Registry entries are owned by this process and cleared on exit; the
    # broadcast tells other sockets the list changed.
    Sessions.broadcast_changed()
    :ok
  end

  defp dispatch("KeepAlive", state), do: {:push, {:text, WsMessage.keep_alive()}, state}

  defp dispatch(type, state) when type in @noop_types, do: {:ok, state}

  defp dispatch("SessionsStart", state) do
    state = %{state | subscriptions: MapSet.put(state.subscriptions, "Sessions")}
    {:push, {:text, sessions_message(state)}, state}
  end

  defp dispatch("SessionsStop", state) do
    {:ok, %{state | subscriptions: MapSet.delete(state.subscriptions, "Sessions")}}
  end

  defp dispatch(type, state) do
    Logger.debug("jellyfin socket: unhandled MessageType #{inspect(type)}")
    {:ok, state}
  end

  defp sessions_message(state) do
    sessions =
      state.user_id
      |> Sessions.live_for_user()
      |> Enum.map(fn {at, play_state} ->
        # controllable: true is unconditional, not per-entry, because
        # live_for_user/2 only ever returns access tokens with a live socket
        # — every entry here is controllable by definition. If live_for_user/2
        # is ever widened to include sessions without a live socket, this
        # becomes wrong silently; re-derive controllable per-entry then.
        SessionDto.from_access_token(at, state: play_state, controllable: true)
      end)

    WsMessage.encode("Sessions", sessions)
  end
end
