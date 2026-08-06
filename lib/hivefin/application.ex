defmodule Hivefin.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    children = [
      HivefinWeb.Telemetry,
      Hivefin.Repo,
      {DNSCluster, query: Application.get_env(:hivefin, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Hivefin.PubSub},
      {Task.Supervisor, name: Hivefin.Scanner.TaskSupervisor},
      Hivefin.Scanner,
      {Registry, keys: :unique, name: Hivefin.Playback.Registry},
      Hivefin.Playback.Supervisor,
      # Start to serve requests, typically the last entry
      HivefinWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Hivefin.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        maybe_bootstrap_admin()
        {:ok, pid}

      error ->
        error
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    HivefinWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp maybe_bootstrap_admin do
    if Application.get_env(:hivefin, :bootstrap_admin_on_start, true) do
      case Hivefin.Accounts.bootstrap_admin() do
        {:ok, _user} ->
          :ok

        {:error, :missing_bootstrap_env} ->
          Logger.debug("Admin bootstrap skipped: HIVEFIN_ADMIN_USER/PASSWORD not set")

        {:error, reason} ->
          Logger.warning("Admin bootstrap failed: #{inspect(reason)}")
      end
    end
  end
end
