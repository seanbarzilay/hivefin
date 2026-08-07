defmodule Hivefin.Jellyfin.SystemInfo do
  @moduledoc """
  Server identity and System/Info payloads for Jellyfin clients.

  Discovery (System/Info/Public) must satisfy @jellyfin/sdk RecommendedServerDiscovery:

  - `ProductName` must be exactly `"Jellyfin Server"` (otherwise score BAD → "Server not found")
  - `Version` must be >= the client's API_VERSION (currently 12.0.0 for jellyfin-vue)
    or discovery rejects as outdated/unsupported

  The real Mix app version is available via `hivefin_version/0` for ops/logging.
  """

  @default_server_id "00000000-0000-4000-8000-000000000001"
  # Matches jellyfin-sdk-typescript API_VERSION used by recent jellyfin-vue builds.
  @default_compatibility_version "12.0.0"
  @discovery_product_name "Jellyfin Server"

  def server_id do
    Application.get_env(:hivefin, :server_id, @default_server_id)
  end

  @doc """
  Version advertised to clients (Jellyfin API compatibility claim).
  """
  def version do
    Application.get_env(:hivefin, :jellyfin_api_version, @default_compatibility_version)
    |> to_string()
  end

  @doc """
  Actual Hivefin OTP application version (not used for client discovery).
  """
  def hivefin_version do
    Application.spec(:hivefin, :vsn) |> to_string()
  end

  def product_name, do: @discovery_product_name

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
