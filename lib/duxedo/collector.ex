defmodule Duxedo.Collector do
  @moduledoc false

  use GenServer
  require Logger

  alias Telemetry.Metrics.Counter

  @max_buffer_size 10_000

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: name(args[:instance]))
  end

  def flush(instance \\ :duxedo) do
    GenServer.call(name(instance), :flush)
  end

  defp name(instance), do: Module.concat(__MODULE__, instance)

  @impl GenServer
  def init(args) do
    instance = args[:instance]
    collect_interval = (args[:collect_interval] || 5) * 1_000
    session = args[:session] || UUID.uuid4()
    metrics = args[:metrics] || []
    events = args[:events] || []

    handler_ids = register_metrics(instance, metrics, session) ++ register_events(instance, events, session)

    state = %{
      instance: instance,
      collect_interval: collect_interval,
      session: session,
      handler_ids: handler_ids,
      obs_buffer: [],
      event_buffer: []
    }

    schedule_flush(collect_interval)
    {:ok, state}
  end

  @impl GenServer
  def handle_cast({:observation, obs}, state) do
    buffer = [obs | state.obs_buffer]

    buffer =
      if length(buffer) > @max_buffer_size do
        Logger.warning("Duxedo: observation buffer overflow, dropping oldest entries")
        Enum.take(buffer, @max_buffer_size)
      else
        buffer
      end

    {:noreply, %{state | obs_buffer: buffer}}
  end

  def handle_cast({:event, event}, state) do
    buffer = [event | state.event_buffer]

    buffer =
      if length(buffer) > @max_buffer_size do
        Enum.take(buffer, @max_buffer_size)
      else
        buffer
      end

    {:noreply, %{state | event_buffer: buffer}}
  end

  @impl GenServer
  def handle_call(:flush, _from, state) do
    state = do_flush(state)
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_info(:flush, state) do
    state = do_flush(state)
    schedule_flush(state.collect_interval)
    {:noreply, state}
  end

  @impl GenServer
  def terminate(_reason, state) do
    detach_handlers(state.handler_ids)
    do_flush(state)
  end

  defp do_flush(%{obs_buffer: [], event_buffer: []} = state), do: state

  defp do_flush(state) do
    conn = Duxedo.Store.memory_conn(state.instance)

    state =
      if state.obs_buffer != [] do
        columns = build_observation_columns(state.obs_buffer)

        try do
          Adbc.Connection.bulk_insert!(conn, columns, table: "observations", mode: :append)
          %{state | obs_buffer: []}
        rescue
          e ->
            Logger.warning("Duxedo: observation flush failed: #{Exception.message(e)}")
            state
        end
      else
        state
      end

    if state.event_buffer != [] do
      columns = build_event_columns(state.event_buffer)

      try do
        Adbc.Connection.bulk_insert!(conn, columns, table: "events", mode: :append)
        %{state | event_buffer: []}
      rescue
        e ->
          Logger.warning("Duxedo: event flush failed: #{Exception.message(e)}")
          state
      end
    else
      state
    end
  end

  defp build_observation_columns(observations) do
    [
      Adbc.Column.s64(Enum.map(observations, & &1.ts), name: "ts"),
      Adbc.Column.string(Enum.map(observations, & &1.event), name: "event"),
      Adbc.Column.string(Enum.map(observations, & &1.field), name: "field"),
      Adbc.Column.f64(Enum.map(observations, & &1.value), name: "value"),
      Adbc.Column.string(Enum.map(observations, & &1.tags), name: "tags"),
      Adbc.Column.string(Enum.map(observations, & &1.session), name: "session")
    ]
  end

  defp build_event_columns(events) do
    [
      Adbc.Column.s64(Enum.map(events, & &1.ts), name: "ts"),
      Adbc.Column.string(Enum.map(events, & &1.name), name: "name"),
      Adbc.Column.string(Enum.map(events, & &1.measurements), name: "measurements"),
      Adbc.Column.string(Enum.map(events, & &1.tags), name: "tags"),
      Adbc.Column.string(Enum.map(events, & &1.session), name: "session")
    ]
  end

  # --- Telemetry registration ---

  defp register_metrics(instance, metrics, session) do
    for {event, grouped_metrics} <- Enum.group_by(metrics, & &1.event_name) do
      id = {__MODULE__, :metric, event, instance}

      :telemetry.attach(id, event, &__MODULE__.handle_telemetry_metric/4, %{
        instance: instance,
        metrics: grouped_metrics,
        session: session
      })

      id
    end
  end

  defp register_events(instance, events, session) do
    for event_def <- events do
      {event_name, event_opts} = parse_event_def(event_def)
      id = {__MODULE__, :event, event_name, instance}

      :telemetry.attach(id, event_name, &__MODULE__.handle_telemetry_event/4, %{
        instance: instance,
        event_opts: event_opts,
        session: session
      })

      id
    end
  end

  defp parse_event_def({name, opts}) when is_binary(name), do: {parse_event_name(name), opts}
  defp parse_event_def(name) when is_binary(name), do: {parse_event_name(name), []}

  defp parse_event_name(name) do
    name |> String.split(".", trim: true) |> Enum.map(&String.to_atom/1)
  end

  defp detach_handlers(ids) do
    Enum.each(ids, fn id ->
      :telemetry.detach(id)
    end)
  end

  # --- Telemetry handler callbacks ---

  def handle_telemetry_metric(_event, measurements, metadata, config) do
    for metric <- config.metrics do
      try do
        measurement = extract_measurement(metric, measurements, metadata)

        if measurement != nil and keep?(metric, metadata) do
          tags = extract_tags(metric, metadata)
          value = if is_struct(metric, Counter), do: 1.0, else: measurement / 1

          obs = %{
            ts: System.system_time(:second),
            event: Enum.join(metric.name, "."),
            field: field_name(metric),
            value: value,
            tags: JSON.encode!(tags),
            session: config.session
          }

          GenServer.cast(name(config.instance), {:observation, obs})
        end
      rescue
        e ->
          Logger.error("Duxedo: metric handler error: #{Exception.message(e)}")
      end
    end

    :ok
  end

  def handle_telemetry_event(event_name, measurements, metadata, config) do
    try do
      tags = get_event_tags(metadata, config.event_opts)

      event = %{
        ts: System.system_time(:second),
        name: Enum.join(event_name, "."),
        measurements: JSON.encode!(measurements),
        tags: JSON.encode!(tags),
        session: config.session
      }

      GenServer.cast(name(config.instance), {:event, event})
    rescue
      e ->
        Logger.error("Duxedo: event handler error: #{Exception.message(e)}")
    end

    :ok
  end

  defp extract_measurement(%Counter{}, _measurements, _metadata), do: 1
  defp extract_measurement(metric, measurements, metadata) do
    case metric.measurement do
      fun when is_function(fun, 1) -> fun.(measurements)
      fun when is_function(fun, 2) -> fun.(measurements, metadata)
      key -> measurements[key]
    end
  end

  defp keep?(%{keep: nil}, _metadata), do: true
  defp keep?(metric, metadata), do: metric.keep.(metadata)

  defp extract_tags(metric, metadata) do
    tag_values = metric.tag_values.(metadata)
    Map.take(tag_values, metric.tags)
  end

  defp get_event_tags(metadata, opts) do
    allowed = opts[:tags] || []

    Enum.reduce(allowed, %{}, fn tag, acc ->
      case Map.get(metadata, tag) do
        nil -> acc
        value -> Map.put(acc, tag, value)
      end
    end)
  end

  defp field_name(%{measurement: key}) when is_atom(key), do: Atom.to_string(key)
  defp field_name(_metric), do: "value"

  defp schedule_flush(interval), do: Process.send_after(self(), :flush, interval)
end
