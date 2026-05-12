defmodule DuxedoTest do
  use ExUnit.Case, async: false

  alias Telemetry.Metrics

  # Helper to start a Duxedo instance with a unique name and tmp dir
  defp start_duxedo(context, extra_opts \\ []) do
    safe_name =
      context.test
      |> Atom.to_string()
      |> String.replace(~r/[^a-zA-Z0-9]/, "_")
      |> String.slice(0, 60)

    instance = :"t_#{safe_name}"
    tmp_dir = System.tmp_dir!() |> Path.join("duxedo_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)

    default_opts = [
      instance: instance,
      persistence_dir: tmp_dir,
      memory_limit: "32MB",
      flush_interval: 3600,
      collect_interval: 3600,
      retention: [memory: {1, :hour}, disk: {30, :day}],
      metrics: [
        Metrics.last_value("vm.memory.total"),
        Metrics.counter("http.request.count"),
        Metrics.summary("http.request.duration", tags: [:method]),
        Metrics.last_value("cpu.utilization")
      ],
      events: [
        {"button.pressed", tags: [:id]},
        "system.boot"
      ]
    ]

    opts = Keyword.merge(default_opts, extra_opts) |> Keyword.put(:instance, instance)
    start_supervised!({Duxedo, opts})

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    %{instance: instance, tmp_dir: tmp_dir}
  end

  # Helper to insert observations directly into DuckDB, bypassing telemetry
  defp insert_observations(instance, rows) do
    conn = Duxedo.Store.memory_conn(instance)

    columns = [
      Adbc.Column.s64(Enum.map(rows, & &1.ts), name: "ts"),
      Adbc.Column.string(Enum.map(rows, & &1.event), name: "event"),
      Adbc.Column.string(Enum.map(rows, & &1.field), name: "field"),
      Adbc.Column.f64(Enum.map(rows, & &1.value), name: "value"),
      Adbc.Column.string(Enum.map(rows, fn r -> r[:tags] || "{}" end), name: "tags"),
      Adbc.Column.string(Enum.map(rows, fn r -> r[:session] || "test" end), name: "session")
    ]

    Adbc.Connection.bulk_insert!(conn, columns, table: "observations", mode: :append)
  end

  defp insert_events(instance, rows) do
    conn = Duxedo.Store.memory_conn(instance)

    columns = [
      Adbc.Column.s64(Enum.map(rows, & &1.ts), name: "ts"),
      Adbc.Column.string(Enum.map(rows, & &1.name), name: "name"),
      Adbc.Column.string(Enum.map(rows, & &1.measurements), name: "measurements"),
      Adbc.Column.string(Enum.map(rows, fn r -> r[:tags] || "{}" end), name: "tags"),
      Adbc.Column.string(Enum.map(rows, fn r -> r[:session] || "test" end), name: "session")
    ]

    Adbc.Connection.bulk_insert!(conn, columns, table: "events", mode: :append)
  end

  defp row_count(conn, table) do
    result = Adbc.Connection.query!(conn, "SELECT count(*) as n FROM #{table}")
    [[col]] = result.data
    col |> Adbc.Column.materialize() |> Adbc.Column.to_list() |> hd()
  end

  # ── Store ──────────────────────────���───────────────────────────────

  describe "Store" do
    test "creates tables on both in-memory and on-disk databases", context do
      %{instance: inst} = start_duxedo(context)

      mem = Duxedo.Store.memory_conn(inst)
      disk = Duxedo.Store.disk_conn(inst)

      # Should not raise — tables exist
      Adbc.Connection.query!(mem, "SELECT count(*) FROM observations")
      Adbc.Connection.query!(mem, "SELECT count(*) FROM events")
      Adbc.Connection.query!(disk, "SELECT count(*) FROM observations")
      Adbc.Connection.query!(disk, "SELECT count(*) FROM events")
    end

    test "connections are accessible via persistent_term", context do
      %{instance: inst} = start_duxedo(context)

      assert is_pid(Duxedo.Store.memory_conn(inst))
      assert is_pid(Duxedo.Store.disk_conn(inst))
    end

    test "flush_to_disk moves old data from memory to disk", context do
      %{instance: inst} = start_duxedo(context, retention: [memory: {10, :second}, disk: {30, :day}])

      now = System.system_time(:second)

      # Insert data: some old (>10s ago), some recent
      insert_observations(inst, [
        %{ts: now - 60, event: "old.metric", field: "val", value: 1.0},
        %{ts: now - 30, event: "old.metric", field: "val", value: 2.0},
        %{ts: now, event: "new.metric", field: "val", value: 3.0}
      ])

      mem = Duxedo.Store.memory_conn(inst)
      disk = Duxedo.Store.disk_conn(inst)

      assert row_count(mem, "observations") == 3
      assert row_count(disk, "observations") == 0

      Duxedo.Store.flush_to_disk(inst)

      # Old data moved to disk, recent data stays in memory
      assert row_count(mem, "observations") == 1
      assert row_count(disk, "observations") == 2
    end

    test "flush_to_disk also moves old events", context do
      %{instance: inst} = start_duxedo(context, retention: [memory: {10, :second}, disk: {30, :day}])

      now = System.system_time(:second)

      insert_events(inst, [
        %{ts: now - 60, name: "old.event", measurements: "{}"},
        %{ts: now, name: "new.event", measurements: "{}"}
      ])

      Duxedo.Store.flush_to_disk(inst)

      mem = Duxedo.Store.memory_conn(inst)
      disk = Duxedo.Store.disk_conn(inst)

      assert row_count(mem, "events") == 1
      assert row_count(disk, "events") == 1
    end

    test "retention deletes old data from both databases", context do
      %{instance: inst} = start_duxedo(context, retention: [memory: {10, :second}, disk: {5, :second}])

      now = System.system_time(:second)
      mem = Duxedo.Store.memory_conn(inst)
      disk = Duxedo.Store.disk_conn(inst)

      # Insert old data directly into both databases
      insert_observations(inst, [
        %{ts: now - 60, event: "old", field: "v", value: 1.0},
        %{ts: now, event: "new", field: "v", value: 2.0}
      ])

      # Also insert old data into disk directly
      disk_cols = [
        Adbc.Column.s64([now - 60, now], name: "ts"),
        Adbc.Column.string(["old", "new"], name: "event"),
        Adbc.Column.string(["v", "v"], name: "field"),
        Adbc.Column.f64([1.0, 2.0], name: "value"),
        Adbc.Column.string(["{}", "{}"], name: "tags"),
        Adbc.Column.string(["t", "t"], name: "session")
      ]

      Adbc.Connection.bulk_insert!(disk, disk_cols, table: "observations", mode: :append)

      assert row_count(mem, "observations") == 2
      assert row_count(disk, "observations") == 2

      Duxedo.Store.run_retention(inst)

      # Memory: only data within 10s retained
      assert row_count(mem, "observations") == 1
      # Disk: only data within 5s retained
      assert row_count(disk, "observations") == 1
    end

    test "clock sync adjusts timestamps in memory", context do
      %{instance: inst} = start_duxedo(context)

      now = System.system_time(:second)
      insert_observations(inst, [
        %{ts: now, event: "test.metric", field: "v", value: 42.0}
      ])

      # Simulate clock sync message with +100s adjustment
      store_pid = GenServer.whereis(Module.concat(Duxedo.Store, inst))
      send(store_pid, {Duxedo.TimeServer, 100})

      # Give the GenServer a moment to process
      :sys.get_state(store_pid)

      # Timestamp should now be now + 100
      mem = Duxedo.Store.memory_conn(inst)

      result = Adbc.Connection.query!(mem, "SELECT ts FROM observations")
      [[col]] = result.data
      [ts] = col |> Adbc.Column.materialize() |> Adbc.Column.to_list()
      assert ts == now + 100
    end

    test "zero clock adjustment is a no-op", context do
      %{instance: inst} = start_duxedo(context)

      now = System.system_time(:second)
      insert_observations(inst, [
        %{ts: now, event: "test", field: "v", value: 1.0}
      ])

      store_pid = GenServer.whereis(Module.concat(Duxedo.Store, inst))
      send(store_pid, {Duxedo.TimeServer, 0})
      :sys.get_state(store_pid)

      mem = Duxedo.Store.memory_conn(inst)
      result = Adbc.Connection.query!(mem, "SELECT ts FROM observations")
      [[col]] = result.data
      [ts] = col |> Adbc.Column.materialize() |> Adbc.Column.to_list()
      assert ts == now
    end

    test "flush is resilient when there's no data to move", context do
      %{instance: inst} = start_duxedo(context)

      # Should not crash
      assert :ok = Duxedo.Store.flush_to_disk(inst)
    end

    test "repeated flushes don't duplicate data", context do
      %{instance: inst} = start_duxedo(context, retention: [memory: {10, :second}, disk: {30, :day}])

      now = System.system_time(:second)

      insert_observations(inst, [
        %{ts: now - 60, event: "old", field: "v", value: 1.0}
      ])

      Duxedo.Store.flush_to_disk(inst)
      Duxedo.Store.flush_to_disk(inst)
      Duxedo.Store.flush_to_disk(inst)

      disk = Duxedo.Store.disk_conn(inst)
      assert row_count(disk, "observations") == 1
    end
  end

  # ── Collector ──────────��────────────────────────���──────────────────

  describe "Collector" do
    test "telemetry events arrive in DuckDB after flush", context do
      %{instance: inst} = start_duxedo(context)

      :telemetry.execute([:vm, :memory], %{total: 42_000_000}, %{})
      Duxedo.Collector.flush(inst)

      assert Duxedo.Query.count("vm.memory.total", instance: inst) == 1
    end

    test "counter metrics store value 1.0 regardless of measurement", context do
      %{instance: inst} = start_duxedo(context)

      :telemetry.execute([:http, :request], %{count: 999}, %{})
      Duxedo.Collector.flush(inst)

      # Counter should store 1.0, not the measurement value
      assert Duxedo.Query.sum("http.request.count", instance: inst) == 1.0
    end

    test "multiple counter events accumulate correctly", context do
      %{instance: inst} = start_duxedo(context)

      for _ <- 1..100 do
        :telemetry.execute([:http, :request], %{count: 1}, %{})
      end

      Duxedo.Collector.flush(inst)
      assert Duxedo.Query.count("http.request.count", instance: inst) == 100
    end

    test "tags are extracted and stored as JSON", context do
      %{instance: inst} = start_duxedo(context)

      :telemetry.execute([:http, :request], %{duration: 42}, %{method: "GET"})
      Duxedo.Collector.flush(inst)

      rows = Duxedo.Query.observations("http.request.duration", instance: inst) |> Dux.to_rows()
      assert length(rows) == 1

      tags = rows |> hd() |> Map.get("tags")
      assert JSON.decode!(tags) == %{"method" => "GET"}
    end

    test "only configured tags are extracted", context do
      %{instance: inst} = start_duxedo(context)

      # :method is configured as a tag, :path is not
      :telemetry.execute([:http, :request], %{duration: 42}, %{method: "GET", path: "/foo"})
      Duxedo.Collector.flush(inst)

      rows = Duxedo.Query.observations("http.request.duration", instance: inst) |> Dux.to_rows()
      tags = rows |> hd() |> Map.get("tags") |> JSON.decode!()

      assert tags == %{"method" => "GET"}
      refute Map.has_key?(tags, "path")
    end

    test "events are stored with measurements and tags", context do
      %{instance: inst} = start_duxedo(context)

      :telemetry.execute([:button, :pressed], %{force: 0.8, duration: 50}, %{id: "btn1"})
      Duxedo.Collector.flush(inst)

      rows = Duxedo.Query.events("button.pressed", instance: inst) |> Dux.to_rows()
      assert length(rows) == 1

      event = hd(rows)
      measurements = JSON.decode!(event["measurements"])
      tags = JSON.decode!(event["tags"])

      assert measurements["force"] == 0.8
      assert measurements["duration"] == 50
      assert tags["id"] == "btn1"
    end

    test "events without configured tags store empty tags", context do
      %{instance: inst} = start_duxedo(context)

      :telemetry.execute([:system, :boot], %{time: 1234}, %{extra: "ignored"})
      Duxedo.Collector.flush(inst)

      rows = Duxedo.Query.events("system.boot", instance: inst) |> Dux.to_rows()
      assert length(rows) == 1

      tags = rows |> hd() |> Map.get("tags") |> JSON.decode!()
      assert tags == %{}
    end

    test "session is attached to all observations", context do
      %{instance: inst} = start_duxedo(context)

      :telemetry.execute([:vm, :memory], %{total: 1}, %{})
      Duxedo.Collector.flush(inst)

      rows = Duxedo.Query.observations("vm.memory.total", instance: inst) |> Dux.to_rows()
      session = rows |> hd() |> Map.get("session")

      assert is_binary(session)
      assert String.length(session) > 0
    end

    test "flush with empty buffer is a no-op", context do
      %{instance: inst} = start_duxedo(context)

      # Should not crash and should not insert anything
      Duxedo.Collector.flush(inst)

      assert Duxedo.Query.list_metrics(instance: inst) == []
    end

    test "multiple metrics on the same telemetry event are captured", context do
      %{instance: inst} = start_duxedo(context)

      # http.request event has both counter and summary metrics configured
      :telemetry.execute([:http, :request], %{count: 1, duration: 150}, %{method: "POST"})
      Duxedo.Collector.flush(inst)

      assert Duxedo.Query.count("http.request.count", instance: inst) == 1
      assert Duxedo.Query.count("http.request.duration", instance: inst) == 1
    end

    test "measurement values are stored as floats", context do
      %{instance: inst} = start_duxedo(context)

      :telemetry.execute([:vm, :memory], %{total: 42}, %{})
      Duxedo.Collector.flush(inst)

      val = Duxedo.Query.last_value("vm.memory.total", instance: inst)
      assert is_float(val)
      assert val == 42.0
    end

    test "field name is derived from metric measurement key", context do
      %{instance: inst} = start_duxedo(context)

      :telemetry.execute([:vm, :memory], %{total: 1}, %{})
      :telemetry.execute([:http, :request], %{duration: 2}, %{method: "GET"})
      Duxedo.Collector.flush(inst)

      mem_rows = Duxedo.Query.observations("vm.memory.total", instance: inst) |> Dux.to_rows()
      assert hd(mem_rows)["field"] == "total"

      dur_rows = Duxedo.Query.observations("http.request.duration", instance: inst) |> Dux.to_rows()
      assert hd(dur_rows)["field"] == "duration"
    end
  end

  # ── Query: time ranges ────────────��────────────────────────────────

  describe "Query time ranges" do
    test ":from and :to filter correctly", context do
      %{instance: inst} = start_duxedo(context)
      now = System.system_time(:second)

      insert_observations(inst, [
        %{ts: now - 100, event: "m", field: "v", value: 1.0},
        %{ts: now - 50, event: "m", field: "v", value: 2.0},
        %{ts: now - 10, event: "m", field: "v", value: 3.0}
      ])

      # Only the middle one
      assert Duxedo.Query.count("m", instance: inst, from: now - 60, to: now - 40) == 1
    end

    test ":from without :to queries up to now", context do
      %{instance: inst} = start_duxedo(context)
      now = System.system_time(:second)

      insert_observations(inst, [
        %{ts: now - 100, event: "m", field: "v", value: 1.0},
        %{ts: now - 10, event: "m", field: "v", value: 2.0}
      ])

      assert Duxedo.Query.count("m", instance: inst, from: now - 50) == 1
    end

    test ":last with integer (seconds)", context do
      %{instance: inst} = start_duxedo(context)
      now = System.system_time(:second)

      insert_observations(inst, [
        %{ts: now - 100, event: "m", field: "v", value: 1.0},
        %{ts: now - 10, event: "m", field: "v", value: 2.0}
      ])

      assert Duxedo.Query.count("m", instance: inst, last: 30) == 1
    end

    test ":last with tuple", context do
      %{instance: inst} = start_duxedo(context)
      now = System.system_time(:second)

      insert_observations(inst, [
        %{ts: now - 7200, event: "m", field: "v", value: 1.0},
        %{ts: now - 10, event: "m", field: "v", value: 2.0}
      ])

      assert Duxedo.Query.count("m", instance: inst, last: {1, :hour}) == 1
    end

    test "default time range is 3 minutes", context do
      %{instance: inst} = start_duxedo(context)
      now = System.system_time(:second)

      insert_observations(inst, [
        %{ts: now - 300, event: "m", field: "v", value: 1.0},
        %{ts: now - 10, event: "m", field: "v", value: 2.0}
      ])

      # Default is last 180s, so only the recent one
      assert Duxedo.Query.count("m", instance: inst) == 1
    end

    test "data outside time range is excluded from all query types", context do
      %{instance: inst} = start_duxedo(context)
      now = System.system_time(:second)

      insert_observations(inst, [
        %{ts: now - 500, event: "m", field: "v", value: 100.0},
        %{ts: now - 10, event: "m", field: "v", value: 5.0}
      ])

      # Default 3 min window should exclude the old data
      assert Duxedo.Query.last_value("m", instance: inst) == 5.0
      assert Duxedo.Query.summary("m", instance: inst)["min"] == 5.0
      assert Duxedo.Query.sum("m", instance: inst) == 5.0
      assert Duxedo.Query.series("m", instance: inst) == [5.0]
    end
  end

  # ── Query: tag filtering ────────────────��──────────────────────────

  describe "Query tag filtering" do
    test "filters by single tag", context do
      %{instance: inst} = start_duxedo(context)
      now = System.system_time(:second)

      insert_observations(inst, [
        %{ts: now, event: "m", field: "v", value: 1.0, tags: ~s({"env":"prod"})},
        %{ts: now, event: "m", field: "v", value: 2.0, tags: ~s({"env":"staging"})},
        %{ts: now, event: "m", field: "v", value: 3.0, tags: ~s({"env":"prod"})}
      ])

      assert Duxedo.Query.count("m", instance: inst, tags: %{env: "prod"}) == 2
      assert Duxedo.Query.count("m", instance: inst, tags: %{env: "staging"}) == 1
    end

    test "filters by multiple tags", context do
      %{instance: inst} = start_duxedo(context)
      now = System.system_time(:second)

      insert_observations(inst, [
        %{ts: now, event: "m", field: "v", value: 1.0, tags: ~s({"env":"prod","region":"us"})},
        %{ts: now, event: "m", field: "v", value: 2.0, tags: ~s({"env":"prod","region":"eu"})},
        %{ts: now, event: "m", field: "v", value: 3.0, tags: ~s({"env":"staging","region":"us"})}
      ])

      assert Duxedo.Query.count("m", instance: inst, tags: %{env: "prod", region: "us"}) == 1
    end

    test "no tag filter returns all data", context do
      %{instance: inst} = start_duxedo(context)
      now = System.system_time(:second)

      insert_observations(inst, [
        %{ts: now, event: "m", field: "v", value: 1.0, tags: ~s({"env":"prod"})},
        %{ts: now, event: "m", field: "v", value: 2.0, tags: ~s({"env":"staging"})}
      ])

      assert Duxedo.Query.count("m", instance: inst) == 2
    end

    test "empty tags map returns all data", context do
      %{instance: inst} = start_duxedo(context)
      now = System.system_time(:second)

      insert_observations(inst, [
        %{ts: now, event: "m", field: "v", value: 1.0}
      ])

      assert Duxedo.Query.count("m", instance: inst, tags: %{}) == 1
    end

    test "tag filter with no matches returns empty/zero", context do
      %{instance: inst} = start_duxedo(context)
      now = System.system_time(:second)

      insert_observations(inst, [
        %{ts: now, event: "m", field: "v", value: 1.0, tags: ~s({"env":"prod"})}
      ])

      assert Duxedo.Query.count("m", instance: inst, tags: %{env: "nonexistent"}) == 0
      assert Duxedo.Query.last_value("m", instance: inst, tags: %{env: "nonexistent"}) == nil
      assert Duxedo.Query.series("m", instance: inst, tags: %{env: "nonexistent"}) == []
    end
  end

  # ── Query: aggregations ────────────────────────���───────────────────

  describe "Query aggregations" do
    test "summary with a single data point", context do
      %{instance: inst} = start_duxedo(context)
      now = System.system_time(:second)

      insert_observations(inst, [
        %{ts: now, event: "m", field: "v", value: 42.0}
      ])

      stats = Duxedo.Query.summary("m", instance: inst)
      assert stats["min"] == 42.0
      assert stats["max"] == 42.0
      assert stats["avg"] == 42.0
      assert stats["count"] == 1
      # stddev of a single value is NULL
      assert stats["std_dev"] == nil
    end

    test "summary with no data returns empty result", context do
      %{instance: inst} = start_duxedo(context)

      stats = Duxedo.Query.summary("nonexistent", instance: inst)
      assert stats["count"] == 0 || stats["count"] == nil
    end

    test "last_value returns nil for nonexistent metric", context do
      %{instance: inst} = start_duxedo(context)
      assert Duxedo.Query.last_value("nonexistent", instance: inst) == nil
    end

    test "count returns 0 for nonexistent metric", context do
      %{instance: inst} = start_duxedo(context)
      assert Duxedo.Query.count("nonexistent", instance: inst) == 0
    end

    test "sum returns 0 for nonexistent metric", context do
      %{instance: inst} = start_duxedo(context)
      assert Duxedo.Query.sum("nonexistent", instance: inst) == 0
    end

    test "sum accumulates all values", context do
      %{instance: inst} = start_duxedo(context)
      now = System.system_time(:second)

      insert_observations(inst, [
        %{ts: now, event: "m", field: "v", value: 10.0},
        %{ts: now, event: "m", field: "v", value: 20.0},
        %{ts: now, event: "m", field: "v", value: 30.0}
      ])

      assert Duxedo.Query.sum("m", instance: inst) == 60.0
    end

    test "percentiles on no data returns nils", context do
      %{instance: inst} = start_duxedo(context)

      pcts = Duxedo.Query.percentiles("nonexistent", [50, 99], instance: inst)
      assert pcts[50] == nil
      assert pcts[99] == nil
    end

    test "percentiles on uniform data", context do
      %{instance: inst} = start_duxedo(context)
      now = System.system_time(:second)

      # Insert values 1 through 1000
      rows = for i <- 1..1000 do
        %{ts: now, event: "m", field: "v", value: i / 1}
      end

      insert_observations(inst, rows)

      pcts = Duxedo.Query.percentiles("m", [50, 90, 99], instance: inst)

      assert_in_delta pcts[50], 500.0, 10.0
      assert_in_delta pcts[90], 900.0, 10.0
      assert_in_delta pcts[99], 990.0, 10.0
    end
  end

  # ── Query: distribution ─────────────────���──────────────────────────

  describe "Query distribution" do
    test "bins cover the full range", context do
      %{instance: inst} = start_duxedo(context)
      now = System.system_time(:second)

      rows = for i <- 1..100, do: %{ts: now, event: "m", field: "v", value: i / 1}
      insert_observations(inst, rows)

      bins = Duxedo.Query.distribution("m", instance: inst, bins: 10) |> Dux.to_rows()

      total_count = Enum.sum(Enum.map(bins, & &1["count"]))
      assert total_count == 100

      # First bin starts near 1, last bin ends near 100
      first_bin = Enum.min_by(bins, & &1["bin"])
      last_bin = Enum.max_by(bins, & &1["bin"])
      assert first_bin["bin_start"] <= 2.0
      assert last_bin["bin_end"] >= 99.0
    end

    test "distribution with identical values", context do
      %{instance: inst} = start_duxedo(context)
      now = System.system_time(:second)

      rows = for _ <- 1..50, do: %{ts: now, event: "m", field: "v", value: 42.0}
      insert_observations(inst, rows)

      bins = Duxedo.Query.distribution("m", instance: inst, bins: 5) |> Dux.to_rows()

      total = Enum.sum(Enum.map(bins, & &1["count"]))
      assert total == 50
    end
  end

  # ── Query: bucket ──────────────────��───────────────────────────────

  describe "Query bucket" do
    test "groups data into time buckets", context do
      %{instance: inst} = start_duxedo(context)

      # Use bucket-aligned timestamps to avoid boundary issues
      # Pick a base that's a multiple of 60
      base = div(System.system_time(:second), 60) * 60

      insert_observations(inst, [
        %{ts: base - 61, event: "m", field: "v", value: 10.0},
        %{ts: base - 61, event: "m", field: "v", value: 20.0},
        %{ts: base - 1, event: "m", field: "v", value: 30.0},
        %{ts: base - 1, event: "m", field: "v", value: 40.0}
      ])

      rows = Duxedo.Query.bucket("m", 60, instance: inst, from: 0) |> Dux.to_rows()

      assert length(rows) == 2

      [older, newer] = Enum.sort_by(rows, & &1["bucket_ts"])

      assert older["count"] == 2
      assert_in_delta older["avg"], 15.0, 0.01

      assert newer["count"] == 2
      assert_in_delta newer["avg"], 35.0, 0.01
    end

    test "bucket includes min and max", context do
      %{instance: inst} = start_duxedo(context)
      now = System.system_time(:second)

      insert_observations(inst, [
        %{ts: now, event: "m", field: "v", value: 5.0},
        %{ts: now, event: "m", field: "v", value: 95.0}
      ])

      rows = Duxedo.Query.bucket("m", 60, instance: inst) |> Dux.to_rows()

      assert length(rows) == 1
      assert hd(rows)["min"] == 5.0
      assert hd(rows)["max"] == 95.0
    end
  end

  # ── Query: composability ───────────────────────────────────────────

  describe "Query composability" do
    test "observations returns a Dux struct", context do
      %{instance: inst} = start_duxedo(context)

      result = Duxedo.Query.observations("m", instance: inst)
      assert %Dux{} = result
    end

    test "observations can be materialized with to_rows", context do
      %{instance: inst} = start_duxedo(context)
      now = System.system_time(:second)

      insert_observations(inst, [
        %{ts: now, event: "m", field: "v", value: 1.0}
      ])

      rows = Duxedo.Query.observations("m", instance: inst) |> Dux.to_rows()
      assert length(rows) == 1
      assert hd(rows)["value"] == 1.0
    end

    test "observations can be materialized with to_columns", context do
      %{instance: inst} = start_duxedo(context)
      now = System.system_time(:second)

      insert_observations(inst, [
        %{ts: now, event: "m", field: "v", value: 1.0},
        %{ts: now, event: "m", field: "v", value: 2.0}
      ])

      cols = Duxedo.Query.observations("m", instance: inst) |> Dux.to_columns()
      assert cols["value"] == [1.0, 2.0] || Enum.sort(cols["value"]) == [1.0, 2.0]
    end

    test "bucket can be materialized with to_columns", context do
      %{instance: inst} = start_duxedo(context)
      now = System.system_time(:second)

      insert_observations(inst, [
        %{ts: now, event: "m", field: "v", value: 1.0}
      ])

      cols = Duxedo.Query.bucket("m", 60, instance: inst) |> Dux.to_columns()
      assert Map.has_key?(cols, "bucket_ts")
      assert Map.has_key?(cols, "avg")
    end
  end

  # ── Query: source routing ──────────────────���───────────────────────

  describe "Query source routing" do
    test "source: :disk queries the disk database", context do
      %{instance: inst} = start_duxedo(context)
      now = System.system_time(:second)
      disk = Duxedo.Store.disk_conn(inst)

      # Insert directly into disk
      cols = [
        Adbc.Column.s64([now], name: "ts"),
        Adbc.Column.string(["disk.metric"], name: "event"),
        Adbc.Column.string(["v"], name: "field"),
        Adbc.Column.f64([99.0], name: "value"),
        Adbc.Column.string(["{}"], name: "tags"),
        Adbc.Column.string(["s"], name: "session")
      ]

      Adbc.Connection.bulk_insert!(disk, cols, table: "observations", mode: :append)

      # Not in memory
      assert Duxedo.Query.count("disk.metric", instance: inst, source: :memory) == 0
      # But visible on disk
      assert Duxedo.Query.count("disk.metric", instance: inst, source: :disk) == 1
    end
  end

  # ── Query: list_metrics ─────────────────���──────────────────────────

  describe "Query list_metrics" do
    test "returns empty list when no data", context do
      %{instance: inst} = start_duxedo(context)
      assert Duxedo.Query.list_metrics(instance: inst) == []
    end

    test "returns sorted unique metric names", context do
      %{instance: inst} = start_duxedo(context)
      now = System.system_time(:second)

      insert_observations(inst, [
        %{ts: now, event: "b.metric", field: "v", value: 1.0},
        %{ts: now, event: "a.metric", field: "v", value: 2.0},
        %{ts: now, event: "b.metric", field: "v", value: 3.0},
        %{ts: now, event: "c.metric", field: "v", value: 4.0}
      ])

      assert Duxedo.Query.list_metrics(instance: inst) == ["a.metric", "b.metric", "c.metric"]
    end
  end

  # ── Export ────────────��────────────────────────────────────────────

  describe "Export" do
    test "CSV includes headers and data rows", context do
      %{instance: inst} = start_duxedo(context)
      now = System.system_time(:second)

      insert_observations(inst, [
        %{ts: now, event: "m", field: "v", value: 1.0},
        %{ts: now, event: "m", field: "v", value: 2.0}
      ])

      {:ok, csv} = Duxedo.Query.observations("m", instance: inst) |> Duxedo.Export.to_csv()

      lines = String.split(csv, "\n")
      # header + 2 data rows
      assert length(lines) == 3
      assert hd(lines) =~ "event"
      assert hd(lines) =~ "value"
    end

    test "CSV without headers", context do
      %{instance: inst} = start_duxedo(context)
      now = System.system_time(:second)

      insert_observations(inst, [
        %{ts: now, event: "m", field: "v", value: 1.0}
      ])

      {:ok, csv} =
        Duxedo.Query.observations("m", instance: inst)
        |> Duxedo.Export.to_csv(headers: false)

      lines = String.split(csv, "\n")
      assert length(lines) == 1
    end

    test "CSV with empty data", context do
      %{instance: inst} = start_duxedo(context)

      {:ok, csv} = Duxedo.Query.observations("nonexistent", instance: inst) |> Duxedo.Export.to_csv()
      assert csv == ""
    end

    test "CSV from metric name string", context do
      %{instance: inst} = start_duxedo(context)
      now = System.system_time(:second)

      insert_observations(inst, [
        %{ts: now, event: "m", field: "v", value: 1.0}
      ])

      {:ok, csv} = Duxedo.Export.to_csv("m", instance: inst)
      assert csv =~ "value"
    end

    test "CSV escapes values with commas", context do
      %{instance: inst} = start_duxedo(context)
      now = System.system_time(:second)

      insert_observations(inst, [
        %{ts: now, event: "m", field: "v", value: 1.0, tags: ~s({"a":"b,c"})}
      ])

      {:ok, csv} = Duxedo.Query.observations("m", instance: inst) |> Duxedo.Export.to_csv()
      # Tags contain a comma, should be quoted
      assert csv =~ "\""
    end

    test "plot doesn't crash with data", context do
      %{instance: inst} = start_duxedo(context)
      now = System.system_time(:second)

      rows = for i <- 1..20, do: %{ts: now - 20 + i, event: "m", field: "v", value: i / 1}
      insert_observations(inst, rows)

      # Capture IO to verify it doesn't crash and produces output
      output = ExUnit.CaptureIO.capture_io(fn ->
        Duxedo.Export.plot("m", instance: inst)
      end)

      assert output =~ "Metric: m"
    end

    test "plot with no data returns error", context do
      %{instance: inst} = start_duxedo(context)

      result = Duxedo.Export.plot("nonexistent", instance: inst)
      assert {:error, "No data"} = result
    end
  end

  # ── TimeServer ────────────��─────────────────────���──────────────────

  describe "TimeServer" do
    test "synchronized? is true when no clock configured", context do
      %{instance: inst} = start_duxedo(context)
      assert Duxedo.TimeServer.synchronized?(inst) == true
    end

    test "synchronized? is false until clock syncs", context do
      defmodule NeverSyncClock do
        @behaviour Duxedo.Clock
        def synchronized?, do: false
      end

      %{instance: inst} = start_duxedo(context, clock: NeverSyncClock)
      assert Duxedo.TimeServer.synchronized?(inst) == false
    end

    test "notifies registered processes on sync", context do
      defmodule EventuallySyncClock do
        @behaviour Duxedo.Clock
        def synchronized? do
          # Syncs after first check
          case :persistent_term.get(:test_clock_calls, 0) do
            0 ->
              :persistent_term.put(:test_clock_calls, 1)
              false
            _ ->
              true
          end
        end
      end

      :persistent_term.put(:test_clock_calls, 0)

      %{instance: inst} = start_duxedo(context, clock: EventuallySyncClock)

      # Register ourselves
      Duxedo.TimeServer.register(inst, self())

      # Wait for the sync notification (TimeServer checks every 1s)
      assert_receive {Duxedo.TimeServer, adjustment}, 5_000
      assert is_integer(adjustment)

      :persistent_term.erase(:test_clock_calls)
    end
  end

  # ── Integration ────────────────��──────────────────────────���────────

  describe "Integration" do
    test "full lifecycle: emit telemetry, flush, query, export", context do
      %{instance: inst} = start_duxedo(context)

      # Emit various telemetry events
      for i <- 1..10 do
        :telemetry.execute([:vm, :memory], %{total: i * 1_000_000}, %{})
        :telemetry.execute([:http, :request], %{count: 1, duration: i * 10}, %{method: "GET"})
      end

      :telemetry.execute([:button, :pressed], %{force: 0.5}, %{id: "power"})

      Duxedo.Collector.flush(inst)

      # Query
      metrics = Duxedo.Query.list_metrics(instance: inst)
      assert "vm.memory.total" in metrics
      assert "http.request.count" in metrics
      assert "http.request.duration" in metrics

      assert Duxedo.Query.count("http.request.count", instance: inst) == 10
      assert Duxedo.Query.last_value("vm.memory.total", instance: inst) != nil

      stats = Duxedo.Query.summary("http.request.duration", instance: inst)
      assert stats["count"] == 10
      assert stats["min"] == 10.0
      assert stats["max"] == 100.0

      pcts = Duxedo.Query.percentiles("http.request.duration", [50, 99], instance: inst)
      assert pcts[50] != nil

      events = Duxedo.Query.events("button.pressed", instance: inst) |> Dux.to_rows()
      assert length(events) == 1

      # Export
      {:ok, csv} = Duxedo.Export.to_csv("vm.memory.total", instance: inst)
      assert csv =~ "value"
    end

    test "data survives flush to disk and is queryable there", context do
      %{instance: inst} = start_duxedo(context, retention: [memory: {5, :second}, disk: {1, :hour}])
      now = System.system_time(:second)

      insert_observations(inst, [
        %{ts: now - 60, event: "archived", field: "v", value: 42.0}
      ])

      # Before flush: in memory only
      assert Duxedo.Query.count("archived", instance: inst, from: 0) == 1
      assert Duxedo.Query.count("archived", instance: inst, from: 0, source: :disk) == 0

      Duxedo.Store.flush_to_disk(inst)

      # After flush: moved to disk
      assert Duxedo.Query.count("archived", instance: inst, from: 0) == 0
      assert Duxedo.Query.count("archived", instance: inst, from: 0, source: :disk) == 1
    end

    test "high volume: 10k observations", context do
      %{instance: inst} = start_duxedo(context)
      now = System.system_time(:second)

      rows = for _i <- 1..10_000 do
        %{ts: now, event: "bulk", field: "v", value: :rand.uniform() * 100}
      end

      insert_observations(inst, rows)

      assert Duxedo.Query.count("bulk", instance: inst) == 10_000
      stats = Duxedo.Query.summary("bulk", instance: inst)
      assert stats["count"] == 10_000
      assert stats["min"] >= 0.0
      assert stats["max"] <= 100.0
    end
  end
end
