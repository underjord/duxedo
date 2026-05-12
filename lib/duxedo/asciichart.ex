# credo:disable-for-this-file
defmodule Duxedo.Asciichart do
  @moduledoc false

  # ASCII chart generation.
  # Originally from sndnv's elixir asciichart package (https://github.com/sndnv/asciichart)
  # Ported to Elixir from https://github.com/kroitor/asciichart

  def plot(series, cfg \\ %{}) do
    case series do
      [] ->
        {:error, "No data"}

      [_ | _] ->
        minimum = Enum.min(series)
        maximum = Enum.max(series)

        interval = abs(maximum - minimum)
        offset = cfg[:offset] || 3
        height = if cfg[:height], do: cfg[:height] - 1, else: interval
        padding = cfg[:padding] || " "
        ratio = if interval == 0, do: 1, else: height / interval
        min2 = safe_floor(minimum * ratio)
        max2 = safe_ceil(maximum * ratio)

        intmin2 = trunc(min2)
        intmax2 = trunc(max2)

        rows = abs(intmax2 - intmin2)
        width = length(series) + offset

        rows_denom = max(1, rows)

        result =
          0..(rows + 1)
          |> Enum.map(fn x ->
            {x, 0..width |> Enum.map(fn y -> {y, " "} end) |> Enum.into(%{})}
          end)
          |> Enum.into(%{})

        max_label_size =
          (maximum / 1)
          |> Float.round(2)
          |> :erlang.float_to_binary(decimals: 2)
          |> String.length()

        min_label_size =
          (minimum / 1)
          |> Float.round(2)
          |> :erlang.float_to_binary(decimals: 2)
          |> String.length()

        label_size = max(min_label_size, max_label_size)

        result =
          intmin2..intmax2
          |> Enum.reduce(result, fn y, map ->
            label =
              (maximum - (y - intmin2) * interval / rows_denom)
              |> Float.round(2)
              |> :erlang.float_to_binary(decimals: 2)
              |> String.pad_leading(label_size, padding)

            updated_map = put_in(map[y - intmin2][max(offset - String.length(label), 0)], label)
            put_in(updated_map[y - intmin2][offset - 1], if(y == 0, do: "┼", else: "┤"))
          end)

        y0 = trunc(Enum.at(series, 0) * ratio - min2)
        result = put_in(result[rows - y0][offset - 1], "┼")

        result =
          0..(length(series) - 2)
          |> Enum.reduce(result, fn x, map ->
            y0 = trunc(Enum.at(series, x + 0) * ratio - intmin2)
            y1 = trunc(Enum.at(series, x + 1) * ratio - intmin2)

            if y0 == y1 do
              put_in(map[rows - y0][x + offset], "─")
            else
              updated_map =
                put_in(
                  map[rows - y1][x + offset],
                  if(y0 > y1, do: "╰", else: "╭")
                )

              updated_map =
                put_in(
                  updated_map[rows - y0][x + offset],
                  if(y0 > y1, do: "╮", else: "╯")
                )

              (min(y0, y1) + 1)..max(y0, y1)
              |> Enum.drop(-1)
              |> Enum.reduce(updated_map, fn y, map ->
                put_in(map[rows - y][x + offset], "│")
              end)
            end
          end)

        result =
          result
          |> Enum.sort_by(fn {k, _} -> k end)
          |> Enum.map(fn {_, x} ->
            x
            |> Enum.sort_by(fn {k, _} -> k end)
            |> Enum.map(fn {_, y} -> y end)
            |> Enum.join()
          end)
          |> Enum.join("\n")

        {:ok, result}
    end
  end

  defp safe_floor(n) when is_integer(n), do: n
  defp safe_floor(n) when is_float(n), do: Float.floor(n)

  defp safe_ceil(n) when is_integer(n), do: n
  defp safe_ceil(n) when is_float(n), do: Float.ceil(n)
end
