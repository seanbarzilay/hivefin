defmodule Hivefin.Jellyfin.Auth do
  @moduledoc """
  Parse Jellyfin/Emby-style MediaBrowser authorization headers.
  """

  @field ~r/(Client|Device|DeviceId|Version|Token)="([^"]*)"/

  @type auth_fields :: %{
          client: String.t() | nil,
          device: String.t() | nil,
          device_id: String.t() | nil,
          version: String.t() | nil,
          token: String.t() | nil
        }

  @spec parse_authorization(String.t() | nil) :: {:ok, auth_fields()} | {:error, :invalid}
  def parse_authorization(nil), do: {:error, :invalid}

  def parse_authorization(header) when is_binary(header) do
    if String.contains?(header, "MediaBrowser") do
      fields =
        Regex.scan(@field, header)
        |> Map.new(fn [_, k, v] -> {field_key(k), v} end)

      {:ok,
       %{
         client: Map.get(fields, :client),
         device: Map.get(fields, :device),
         device_id: Map.get(fields, :device_id),
         version: Map.get(fields, :version),
         token: empty_to_nil(Map.get(fields, :token))
       }}
    else
      {:error, :invalid}
    end
  end

  defp field_key("Client"), do: :client
  defp field_key("Device"), do: :device
  defp field_key("DeviceId"), do: :device_id
  defp field_key("Version"), do: :version
  defp field_key("Token"), do: :token

  defp empty_to_nil(""), do: nil
  defp empty_to_nil(v), do: v
end
