defmodule Hivefin.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc """
  OTP application entry.

  ## Graceful shutdown

  On SIGTERM / `Application.stop(:hivefin)`:

  1. `prep_stop/1` drains playback: reject new sessions, stop running ones
     (`Session.terminate/2` SIGTERM/SIGKILL FFmpeg and cleans temp dirs).
  2. The root supervisor stops children in reverse start order: Endpoint
     (HTTP), then Playback.Supervisor (double-check drain), workers, Repo.
  3. Session child specs use `shutdown: 5_000` so FFmpeg kill has a bounded wait.

  See `docs/ops.md` for reverse-proxy drain and backup notes.
  """

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
      {Task.Supervisor, name: Hivefin.Metadata.TaskSupervisor},
      Hivefin.Metadata.RateLimiter,
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
        maybe_apply_settings()
        maybe_bootstrap_admin()
        {:ok, pid}

      error ->
        error
    end
  end

  # Called before the supervision tree is torn down (SIGTERM / app stop).
  @impl true
  def prep_stop(state) do
    Logger.info("Hivefin shutting down: draining playback sessions")

    try do
      Hivefin.Playback.Supervisor.drain()
    rescue
      e -> Logger.warning("Playback drain failed: #{Exception.message(e)}")
    catch
      :exit, reason -> Logger.warning("Playback drain exited: #{inspect(reason)}")
    end

    state
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    HivefinWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp maybe_apply_settings do
    try do
      Hivefin.Settings.apply_all!()
    rescue
      e -> Logger.warning("Settings load failed: #{Exception.message(e)}")
    catch
      :exit, reason -> Logger.warning("Settings load exited: #{inspect(reason)}")
    end
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
