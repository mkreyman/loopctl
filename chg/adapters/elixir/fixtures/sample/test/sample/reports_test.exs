defmodule Sample.ReportsTest do
  use Sample.Case, async: true
  test "total", do: assert(Sample.Reports.total([1, 2]) == 3)
  @tag :skip
  test "skipped", do: flunk("never runs")
end
