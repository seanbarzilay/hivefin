defmodule Hivefin.Jellyfin.SystemInfo do
  @moduledoc """
  Server identity and System/Info payloads for Jellyfin clients.

  ProductName is always "Hivefin" — we do not impersonate Jellyfin build hashes.
  Version is the Hivefin application version.
  """

  @default_server_id "00000000-0000-4000-8000-000000000001"

  def server_id do
    Application.get_env(:hivefin, :server_id, @default_server_id)
  end

  def version do
    Application.spec(:hivefin, :vsn) |> to_string()
  end

  def product_name, do: "Hivefin"

  def server_name do
    Application.get_env(:hivefin, :server_name, "Hivefin")
  end

  def local_address do
    Application.get_env(:hivefin, :local_address) || default_local_address()
  end

  @doc """
  Public system info (unauthenticated). Minimal fields clients read at discovery.

  Opts:
  - `:local_address` — override advertised address (request host when known)
  """
  def public_info(opts \\ []) do
    %{
      "LocalAddress" => Keyword.get(opts, :local_address) || local_address(),
      "ServerName" => server_name(),
      "Version" => version(),
      "ProductName" => product_name(),
      "Id" => server_id(),
      "StartupWizardCompleted" => true
    }
  end

  @doc """
  Authenticated system info. Extends public info with safe host details.
  """
  def info(opts \\ []) do
    Map.merge(public_info(opts), %{
      "OperatingSystem" => :os.type() |> format_os(),
      "OperatingSystemDisplayName" => :os.type() |> format_os(),
      "CanSelfRestart" => false,
      "CanLaunchWebBrowser" => false,
      "HasPendingRestart" => false,
      "IsShuttingDown" => false,
      "SupportsLibraryMonitor" => false,
      "WebSocketPortNumber" => endpoint_port(),
      "CompletedInstallations" => [],
      # Fields Android TV / Web clients often read after login
      "HasUpdateAvailable" => false,
      "EncoderLocation" => "None",
      "SystemUpdateLevel" => "Release",
      "CastReceiverApplications" => []
    })
  end


  defp default_local_address do
    "http://127.0.0.1:#{endpoint_port()}"
  end

  defp endpoint_port do
    case Application.get_env(:hivefin, HivefinWeb.Endpoint) do
      nil ->
        4000

      endpoint_cfg ->
        http = Keyword.get(endpoint_cfg, :http, [])
        Keyword.get(http, :port, 4000)
    end
  end

  defp format_os({:unix, family}), do: "Unix/#{family}"
  defp format_os({:win32, _}), do: "Windows"
  defp format_os(other), do: inspect(other)
end
