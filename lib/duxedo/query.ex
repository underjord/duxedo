defmodule Duxedo.Query do
  @moduledoc """
  Query metrics and events stored by Duxedo.

  Functions returning `%Dux{}` are composable — chain further operations,
  materialize with `Dux.to_rows/1`, or convert to Nx tensors with `Dux.to_tensor/1`.

  Terminal functions (`last_value`, `summary`, `count`, `sum`, `percentiles`, `series`)
  execute immediately and return values.

  ## Time range options

  All functions accept:

    * `:from` — unix timestamp (seconds), start of range
    * `:to` — unix timestamp (seconds), end of range
    * `:last` — `seconds` or `{n, :second | :minute | :hour | :day}`, default `{3, :minute}`
    * `:tags` — map of tag filters, e.g. `%{method: "GET"}`
    * `:instance` — Duxedo instance name, default `:duxedo`
    * `:source` — `:memory` (default), `:disk`, or `:all`
  """

  @type opts :: keyword()

  @spec list_metrics(opts()) :: [String.t()]
  def list_metrics(opts \\ []) do
    conn = conn_for(opts)

    %Adbc.Result{data: data} =
      Adbc.Connection.query!(conn, "SELECT DISTINCT event FROM observations ORDER BY event")

    case data do
      [[col]] -> col |> Adbc.Column.materialize() |> Adbc.Column.to_list()
      _ -> []
    end
  end

  @spec observations(String.t(), opts()) :: Dux.t()
  def observations(metric_name, opts \\ []) do
    conn = conn_for(opts)
    {from_ts, to_ts} = resolve_time_range(opts)
    tags_filter = build_tags_filter(opts[:tags])

    Dux.from_query("""
    SELECT ts, event, field, value, tags, session
    FROM observations
    WHERE event = '#{escape(metric_name)}'
    AND ts >= #{from_ts} AND ts <= #{to_ts}
    #{tags_filter}
    ORDER BY ts
    """)
    |> Map.put(:conn, conn)
  end

  @spec events(String.t(), opts()) :: Dux.t()
  def events(event_name, opts \\ []) do
    conn = conn_for(opts)
    {from_ts, to_ts} = resolve_time_range(opts)
    tags_filter = build_tags_filter(opts[:tags])

    Dux.from_query("""
    SELECT ts, name, measurements, tags, session
    FROM events
    WHERE name = '#{escape(event_name)}'
    AND ts >= #{from_ts} AND ts <= #{to_ts}
    #{tags_filter}
    ORDER BY ts
    """)
    |> Map.put(:conn, conn)
  end

  @spec last_value(String.t(), opts()) :: number() | nil
  def last_value(metric_name, opts \\ []) do
    conn = conn_for(opts)
    {from_ts, to_ts} = resolve_time_range(opts)
    tags_filter = build_tags_filter(opts[:tags])

    result =
      Adbc.Connection.query!(conn, """
      SELECT value FROM observations
      WHERE event = '#{escape(metric_name)}'
      AND ts >= #{from_ts} AND ts <= #{to_ts}
      #{tags_filter}
      ORDER BY ts DESC LIMIT 1
      """)

    case result_to_single_value(result, "value") do
      nil -> nil
      val -> val
    end
  end

  @spec summary(String.t(), opts()) :: map()
  def summary(metric_name, opts \\ []) do
    conn = conn_for(opts)
    {from_ts, to_ts} = resolve_time_range(opts)
    tags_filter = build_tags_filter(opts[:tags])

    result =
      Adbc.Connection.query!(conn, """
      SELECT
        min(value) as min,
        max(value) as max,
        avg(value) as avg,
        stddev_samp(value) as std_dev,
        count(*) as count
      FROM observations
      WHERE event = '#{escape(metric_name)}'
      AND ts >= #{from_ts} AND ts <= #{to_ts}
      #{tags_filter}
      """)

    case result_to_rows(result) do
      [row] -> row
      _ -> %{"min" => nil, "max" => nil, "avg" => nil, "std_dev" => nil, "count" => 0}
    end
  end

  @spec count(String.t(), opts()) :: non_neg_integer()
  def count(metric_name, opts \\ []) do
    conn = conn_for(opts)
    {from_ts, to_ts} = resolve_time_range(opts)
    tags_filter = build_tags_filter(opts[:tags])

    result =
      Adbc.Connection.query!(conn, """
      SELECT count(*) as n FROM observations
      WHERE event = '#{escape(metric_name)}'
      AND ts >= #{from_ts} AND ts <= #{to_ts}
      #{tags_filter}
      """)

    result_to_single_value(result, "n") || 0
  end

  @spec sum(String.t(), opts()) :: number()
  def sum(metric_name, opts \\ []) do
    conn = conn_for(opts)
    {from_ts, to_ts} = resolve_time_range(opts)
    tags_filter = build_tags_filter(opts[:tags])

    result =
      Adbc.Connection.query!(conn, """
      SELECT sum(value) as total FROM observations
      WHERE event = '#{escape(metric_name)}'
      AND ts >= #{from_ts} AND ts <= #{to_ts}
      #{tags_filter}
      """)

    result_to_single_value(result, "total") || 0
  end

  @spec percentiles(String.t(), [number()], opts()) :: map()
  def percentiles(metric_name, pcts \\ [50, 90, 95, 99], opts \\ []) do
    conn = conn_for(opts)
    {from_ts, to_ts} = resolve_time_range(opts)
    tags_filter = build_tags_filter(opts[:tags])

    quantile_list = pcts |> Enum.map(&(&1 / 100)) |> inspect()

    result =
      Adbc.Connection.query!(conn, """
      SELECT quantile_cont(value, #{quantile_list}) as pcts
      FROM observations
      WHERE event = '#{escape(metric_name)}'
      AND ts >= #{from_ts} AND ts <= #{to_ts}
      #{tags_filter}
      """)

    case result_to_single_value(result, "pcts") do
      nil ->
        Map.new(pcts, fn p -> {p, nil} end)

      values when is_list(values) ->
        Enum.zip(pcts, values) |> Map.new()

      value ->
        %{hd(pcts) => value}
    end
  end

  @spec distribution(String.t(), opts()) :: Dux.t()
  def distribution(metric_name, opts \\ []) do
    conn = conn_for(opts)
    {from_ts, to_ts} = resolve_time_range(opts)
    tags_filter = build_tags_filter(opts[:tags])
    n_bins = opts[:bins] || 20

    Dux.from_query("""
    WITH bounds AS (
      SELECT min(value) as mn, max(value) as mx
      FROM observations
      WHERE event = '#{escape(metric_name)}'
      AND ts >= #{from_ts} AND ts <= #{to_ts}
      #{tags_filter}
    ),
    binned AS (
      SELECT
        CASE
          WHEN mx = mn THEN 0
          ELSE LEAST(FLOOR((value - mn) / ((mx - mn) / #{n_bins})), #{n_bins - 1})
        END as bin,
        mn, mx
      FROM observations, bounds
      WHERE event = '#{escape(metric_name)}'
      AND ts >= #{from_ts} AND ts <= #{to_ts}
      #{tags_filter}
    )
    SELECT
      bin,
      mn + bin * ((mx - mn) / #{n_bins}) as bin_start,
      mn + (bin + 1) * ((mx - mn) / #{n_bins}) as bin_end,
      count(*) as count
    FROM binned
    GROUP BY bin, mn, mx
    ORDER BY bin
    """)
    |> Map.put(:conn, conn)
  end

  @spec bucket(String.t(), pos_integer(), opts()) :: Dux.t()
  def bucket(metric_name, bucket_seconds \\ 60, opts \\ []) do
    conn = conn_for(opts)
    {from_ts, to_ts} = resolve_time_range(opts)
    tags_filter = build_tags_filter(opts[:tags])

    Dux.from_query("""
    SELECT
      (ts / #{bucket_seconds}) * #{bucket_seconds} as bucket_ts,
      min(value) as min,
      max(value) as max,
      avg(value) as avg,
      count(*) as count
    FROM observations
    WHERE event = '#{escape(metric_name)}'
    AND ts >= #{from_ts} AND ts <= #{to_ts}
    #{tags_filter}
    GROUP BY bucket_ts
    ORDER BY bucket_ts
    """)
    |> Map.put(:conn, conn)
  end

  @spec series(String.t(), opts()) :: [number()]
  def series(metric_name, opts \\ []) do
    conn = conn_for(opts)
    {from_ts, to_ts} = resolve_time_range(opts)
    tags_filter = build_tags_filter(opts[:tags])

    result =
      Adbc.Connection.query!(conn, """
      SELECT value FROM observations
      WHERE event = '#{escape(metric_name)}'
      AND ts >= #{from_ts} AND ts <= #{to_ts}
      #{tags_filter}
      ORDER BY ts
      """)

    case result.data do
      [[col]] -> col |> Adbc.Column.materialize() |> Adbc.Column.to_list()
      _ -> []
    end
  end

  # --- Internal helpers ---

  defp conn_for(opts) do
    instance = opts[:instance] || :duxedo

    case opts[:source] || :memory do
      :memory -> Duxedo.Store.memory_conn(instance)
      :disk -> Duxedo.Store.disk_conn(instance)
      :all -> Duxedo.Store.memory_conn(instance)
    end
  end

  defp resolve_time_range(opts) do
    now = System.system_time(:second)

    cond do
      opts[:from] && opts[:to] ->
        {opts[:from], opts[:to]}

      opts[:from] ->
        {opts[:from], now}

      opts[:last] ->
        {now - last_to_seconds(opts[:last]), now}

      true ->
        {now - 180, now}
    end
  end

  defp last_to_seconds(n) when is_integer(n), do: n
  defp last_to_seconds({n, :second}), do: n
  defp last_to_seconds({n, :minute}), do: n * 60
  defp last_to_seconds({n, :hour}), do: n * 3600
  defp last_to_seconds({n, :day}), do: n * 86400

  defp build_tags_filter(nil), do: ""
  defp build_tags_filter(tags) when map_size(tags) == 0, do: ""

  defp build_tags_filter(tags) do
    clauses =
      Enum.map(tags, fn {k, v} ->
        "json_extract_string(tags, '$.#{escape(to_string(k))}') = '#{escape(to_string(v))}'"
      end)

    "AND " <> Enum.join(clauses, " AND ")
  end

  defp escape(str), do: String.replace(str, "'", "''")

  defp result_to_rows(%Adbc.Result{data: [batch | _]}) do
    columns =
      Enum.map(batch, fn col ->
        materialized = Adbc.Column.materialize(col)
        {materialized.field.name, Adbc.Column.to_list(materialized)}
      end)

    columns_to_rows(columns)
  end

  defp result_to_rows(%Adbc.Result{data: []}), do: []

  defp columns_to_rows([]), do: []

  defp columns_to_rows([{_, first_values} | _] = columns) do
    Enum.map(0..(length(first_values) - 1), &row_at(columns, &1))
  end

  defp row_at(columns, index) do
    Map.new(columns, fn {name, values} -> {name, Enum.at(values, index)} end)
  end

  defp result_to_single_value(result, col_name) do
    case result_to_rows(result) do
      [row | _] -> row[col_name]
      _ -> nil
    end
  end
end
