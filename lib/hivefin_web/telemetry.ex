defmodule HivefinWeb.Telemetry do
  use Supervisor
  import Telemetry.Metrics

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    children = [
      # Telemetry poller will execute the given period measurements
      # every 10_000ms. Learn more here: https://telemetry-metrics.hexdocs.pm
      {:telemetry_poller, measurements: periodic_measurements(), period: 10_000}
      # Add reporters as children of your supervision tree.
      # {Telemetry.Metrics.ConsoleReporter, metrics: metrics()}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  def metrics do
    [
      # Phoenix Metrics
      summary("phoenix.endpoint.start.system_time",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.endpoint.stop.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.start.system_time",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.exception.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.stop.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.socket_connected.duration",
        unit: {:native, :millisecond}
      ),
      sum("phoenix.socket_drain.count"),
      summary("phoenix.channel_joined.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.channel_handled_in.duration",
        tags: [:event],
        unit: {:native, :millisecond}
      ),

      # Database Metrics
      summary("hivefin.repo.query.total_time",
        unit: {:native, :millisecond},
        description: "The sum of the other measurements"
      ),
      summary("hivefin.repo.query.decode_time",
        unit: {:native, :millisecond},
        description: "The time spent decoding the data received from the database"
      ),
      summary("hivefin.repo.query.query_time",
        unit: {:native, :millisecond},
        description: "The time spent executing the query"
      ),
      summary("hivefin.repo.query.queue_time",
        unit: {:native, :millisecond},
        description: "The time spent waiting for a database connection"
      ),
      summary("hivefin.repo.query.idle_time",
        unit: {:native, :millisecond},
        description:
          "The time the connection spent waiting before being checked out for the query"
      ),

      # VM Metrics
      summary("vm.memory.total", unit: {:byte, :kilobyte}),
      summary("vm.total_run_queue_lengths.total"),
      summary("vm.total_run_queue_lengths.cpu"),
      summary("vm.total_run_queue_lengths.io"),

      # Hivefin domain
      summary("hivefin.scan.stop.duration",
        unit: {:native, :millisecond},
        tags: [:library_type, :status],
        description: "Library scan duration"
      ),
      counter("hivefin.playback.start.system_time",
        tags: [:mode, :encoder],
        description: "Playback sessions started"
      ),
      summary("hivefin.playback.stop.duration",
        unit: {:native, :millisecond},
        tags: [:mode, :encoder],
        description: "Playback session lifetime"
      ),
      counter("hivefin.ffmpeg.encoder.system_time",
        tags: [:encoder],
        description: "FFmpeg encoder selections (including CPU fallback)"
      ),
      last_value("hivefin.playback.sessions.active",
        description: "Active FFmpeg playback sessions"
      )
    ]
  end

  defp periodic_measurements do
    [
      {__MODULE__, :dispatch_playback_session_count, []}
    ]
  end

  @doc false
  def dispatch_playback_session_count do
    count =
      try do
        Hivefin.Playback.Supervisor.count_sessions()
      rescue
        _ -> 0
      catch
        :exit, _ -> 0
      end

    :telemetry.execute([:hivefin, :playback, :sessions], %{active: count}, %{})
  end
end
