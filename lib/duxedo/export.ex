defmodule Duxedo.Export do
  @moduledoc """
  Export metric data as Arrow IPC, CSV, or ASCII chart.
  """

  def to_arrow_ipc(%Dux{} = dux) do
    computed = Dux.compute(dux)
    {:table, table_ref} = computed.source
    conn = computed.conn || Dux.Connection.get_conn()

    Adbc.Connection.query_pointer(conn, "SELECT * FROM #{table_ref}", fn stream_result ->
      Adbc.StreamResult.to_ipc_stream(stream_result)
    end)
  end

  def to_arrow_ipc(metric_name, opts \\ []) do
    metric_name
    |> Duxedo.Query.observations(opts)
    |> to_arrow_ipc()
  end

  def from_arrow_ipc(binary) when is_binary(binary) do
    Adbc.StreamResult.from_ipc_stream(binary)
  end

  def to_csv(dux_or_metric, opts \\ [])

  def to_csv(%Dux{} = dux, opts) do
    rows = Dux.to_rows(dux)
    format_csv(rows, opts)
  end

  def to_csv(metric_name, opts) when is_binary(metric_name) do
    metric_name
    |> Duxedo.Query.observations(opts)
    |> to_csv(opts)
  end

  def plot(metric_name, opts \\ []) do
    series = Duxedo.Query.series(metric_name, opts)

    case Duxedo.Asciichart.plot(series, height: opts[:height] || 12) do
      {:ok, chart} ->
        IO.puts([
          "\t\t",
          IO.ANSI.yellow(),
          "Metric: ",
          metric_name,
          IO.ANSI.reset(),
          "\n\n",
          chart
        ])

      error ->
        error
    end
  end

  defp format_csv([], _opts), do: {:ok, ""}

  defp format_csv([first | _] = rows, opts) do
    headers = Map.keys(first) |> Enum.sort()
    include_headers = Keyword.get(opts, :headers, true)

    lines =
      if include_headers do
        [Enum.join(headers, ",") | Enum.map(rows, &row_to_csv(&1, headers))]
      else
        Enum.map(rows, &row_to_csv(&1, headers))
      end

    csv = Enum.join(lines, "\n")

    case opts[:iodevice] do
      nil -> {:ok, csv}
      device ->
        IO.write(device, csv)
        :ok
    end
  end

  defp row_to_csv(row, headers) do
    Enum.map_join(headers, ",", fn h -> csv_escape(row[h]) end)
  end

  defp csv_escape(nil), do: ""
  defp csv_escape(val) when is_binary(val) do
    if String.contains?(val, [",", "\"", "\n"]) do
      "\"" <> String.replace(val, "\"", "\"\"") <> "\""
    else
      val
    end
  end
  defp csv_escape(val), do: to_string(val)
end
