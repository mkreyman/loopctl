defmodule Loopctl.CLI.Output do
  @moduledoc """
  Output formatting for the loopctl CLI.

  Supports three formats:
  - `json` (default) -- machine-readable JSON output
  - `human` -- table/text output for human readability
  - `csv` -- comma-separated values for data export
  """

  alias Loopctl.CLI.Config

  @doc """
  Outputs data in the configured format.

  ## Parameters

  - `data` -- the data to output (map or list)
  - `opts` -- keyword list with optional `:format`, `:headers` (for table/csv)
  """
  @spec render(term(), keyword()) :: :ok
  def render(data, opts \\ []) do
    format = Keyword.get(opts, :format) || Config.format()
    headers = Keyword.get(opts, :headers, [])

    case format do
      "json" -> render_json(data)
      "human" -> render_human(data, headers)
      "csv" -> render_csv(data, headers)
      _ -> render_json(data)
    end
  end

  @doc """
  Outputs an error message to stderr.
  """
  @spec error(String.t()) :: :ok
  def error(message) do
    IO.puts(:stderr, "Error: #{message}")
  end

  @doc """
  Outputs a success message.
  """
  @spec success(String.t()) :: :ok
  def success(message) do
    IO.puts(message)
  end

  # --- Private ---

  defp render_json(data) do
    data
    |> Jason.encode!(pretty: true)
    |> IO.puts()
  end

  defp render_human(data, headers) when is_list(data) and headers != [] do
    # Table output
    rows = Enum.map(data, fn item -> Enum.map(headers, &to_string(Map.get(item, &1, ""))) end)
    header_strs = Enum.map(headers, &to_string/1)

    widths =
      Enum.zip([header_strs | rows])
      |> Enum.map(fn col_values ->
        col_values
        |> Tuple.to_list()
        |> Enum.map(&String.length/1)
        |> Enum.max()
      end)

    fmt_row = fn row ->
      row
      |> Enum.zip(widths)
      |> Enum.map_join("  ", fn {val, w} -> String.pad_trailing(val, w) end)
    end

    IO.puts(fmt_row.(header_strs))
    IO.puts(Enum.map_join(widths, "  ", fn w -> String.duplicate("-", w) end))
    Enum.each(rows, fn row -> IO.puts(fmt_row.(row)) end)
  end

  defp render_human(data, _headers) when is_map(data) do
    data
    |> Enum.each(fn {k, v} ->
      IO.puts("#{k}: #{format_value(v)}")
    end)
  end

  defp render_human(data, _headers) do
    IO.puts(inspect(data, pretty: true))
  end

  defp render_csv(data, headers) when is_list(data) and headers != [] do
    IO.puts(Enum.map_join(headers, ",", &to_string/1))

    Enum.each(data, fn item ->
      row = Enum.map_join(headers, ",", fn h -> csv_escape(Map.get(item, h, "")) end)
      IO.puts(row)
    end)
  end

  defp render_csv(data, _headers) do
    render_json(data)
  end

  defp csv_escape(value) do
    str = to_string(value)

    if String.contains?(str, [",", "\"", "\n"]) do
      "\"#{String.replace(str, "\"", "\"\"")}\""
    else
      str
    end
  end

  defp format_value(v) when is_map(v), do: Jason.encode!(v)
  defp format_value(v) when is_list(v), do: Jason.encode!(v)
  defp format_value(nil), do: ""
  defp format_value(v), do: to_string(v)
end
