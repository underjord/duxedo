defmodule Duxedo do
  @moduledoc """
  Device metrics on DuckDB and Arrow.

  Duxedo collects BEAM telemetry metrics, stores them in an in-memory DuckDB
  database, periodically flushes to disk, and exposes queries as Dux dataframes
  or Arrow IPC for upload.

  ## Usage

      {Duxedo, [
        metrics: [
          Metrics.last_value("vm.memory.total"),
          Metrics.counter("http.request.count"),
          Metrics.summary("http.request.duration", tags: [:method])
        ],
        events: ["nerves.dhcp.lease"],
        persistence_dir: "/data/duxedo",
        memory_limit: "64MB"
      ]}
  """

  use Supervisor

  @default_opts [
    instance: :duxedo,
    persistence_dir: "/data/duxedo",
    memory_limit: "64MB",
    flush_interval: 300,
    collect_interval: 5,
    retention: [memory: {1, :hour}, disk: {30, :day}],
    metrics: [],
    events: []
  ]

  def start_link(opts) do
    opts = Keyword.merge(@default_opts, opts)
    Supervisor.start_link(__MODULE__, opts, name: Module.concat(__MODULE__, opts[:instance]))
  end

  @impl Supervisor
  def init(opts) do
    opts =
      if opts[:session] do
        opts
      else
        Keyword.put(opts, :session, UUID.uuid4())
      end

    children = [
      {Duxedo.TimeServer, opts},
      {Duxedo.Store, opts},
      {Duxedo.Collector, opts}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  defdelegate list_metrics(opts \\ []), to: Duxedo.Query
  defdelegate last_value(metric_name, opts \\ []), to: Duxedo.Query
  defdelegate summary(metric_name, opts \\ []), to: Duxedo.Query
  defdelegate count(metric_name, opts \\ []), to: Duxedo.Query
  defdelegate percentiles(metric_name, pcts \\ [50, 90, 95, 99], opts \\ []), to: Duxedo.Query
  defdelegate series(metric_name, opts \\ []), to: Duxedo.Query
  defdelegate plot(metric_name, opts \\ []), to: Duxedo.Export
end
