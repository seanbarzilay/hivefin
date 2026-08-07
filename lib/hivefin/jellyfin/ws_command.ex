defmodule Hivefin.Jellyfin.WsCommand do
  @moduledoc """
  Builds Jellyfin remote-control message payloads.

  Every payload here has required (non-defaulted) fields in
  jellyfin-sdk-kotlin, so they are always set: `PlayRequest` needs
  `PlayCommand` + `ControllingUserId`, `PlaystateRequest` needs `Command`, and
  `GeneralCommand` needs `Name` + `ControllingUserId` + `Arguments`.
  """

  alias Hivefin.Jellyfin.WsMessage

  @play_commands ~w(PlayNow PlayNext PlayLast PlayInstantMix PlayShuffle)
  @playstate_commands ~w(Stop Pause Unpause NextTrack PreviousTrack Seek Rewind FastForward PlayPause)

  def play_commands, do: @play_commands
  def playstate_commands, do: @playstate_commands

  @doc "Play envelope. Returns `{:error, :invalid_command}` for an unknown PlayCommand."
  def play(controlling_user_id, params) when is_binary(controlling_user_id) and is_map(params) do
    command = params["PlayCommand"] || "PlayNow"

    if command in @play_commands do
      data =
        params
        |> Map.put("PlayCommand", command)
        |> Map.put("ControllingUserId", controlling_user_id)

      WsMessage.build("Play", data)
    else
      {:error, :invalid_command}
    end
  end

  @doc "Playstate envelope. Returns `{:error, :invalid_command}` for an unknown command."
  def playstate(command, params) when is_binary(command) and is_map(params) do
    if command in @playstate_commands do
      WsMessage.build("Playstate", Map.put(params, "Command", command))
    else
      {:error, :invalid_command}
    end
  end

  @doc "GeneralCommand envelope. `Arguments` is always an object of strings."
  def general(name, controlling_user_id, arguments)
      when is_binary(name) and is_binary(controlling_user_id) and is_map(arguments) do
    data = %{
      "Name" => name,
      "ControllingUserId" => controlling_user_id,
      "Arguments" => Map.new(arguments, fn {k, v} -> {to_string(k), to_string(v)} end)
    }

    WsMessage.build("GeneralCommand", data)
  end
end
