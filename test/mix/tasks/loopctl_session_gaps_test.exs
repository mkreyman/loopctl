defmodule Mix.Tasks.Loopctl.SessionGapsTest do
  @moduledoc "TC-52.19.1: gap statistics from fixture transcripts."

  use ExUnit.Case, async: true

  alias Mix.Tasks.Loopctl.SessionGaps

  @t0 ~U[2026-11-01 00:00:00Z]

  defp entry(session, offset) do
    Jason.encode!(%{
      "sessionId" => session,
      "timestamp" => DateTime.to_iso8601(DateTime.add(@t0, offset, :second)),
      "message" => %{"content" => [%{"type" => "tool_use", "name" => "Bash"}]}
    })
  end

  defp text(session, offset) do
    Jason.encode!(%{
      "sessionId" => session,
      "timestamp" => DateTime.to_iso8601(DateTime.add(@t0, offset, :second)),
      "message" => %{"content" => [%{"type" => "text", "text" => "hi"}]}
    })
  end

  @tag :tmp_dir
  test "per-host percentiles, the over-300/3600 counts and skipped lines", %{tmp_dir: dir} do
    host1 = Path.join(dir, "host1")
    host2 = Path.join(dir, "host2")
    File.mkdir_p!(Path.join(host1, "proj"))
    File.mkdir_p!(host2)

    # Session A: gaps 10 and 390 (a text entry between them is not a tool call).
    File.write!(
      Path.join([host1, "proj", "a.jsonl"]),
      Enum.join(
        [entry("A", 0), entry("A", 10), text("A", 200), entry("A", 400), "{not json"],
        "\n"
      )
    )

    # Session B: one gap of 4000.
    File.write!(Path.join(host2, "b.jsonl"), Enum.join([entry("B", 4000), entry("B", 0)], "\n"))

    {h1, skipped1} = SessionGaps.measure_dir(host1)
    {h2, skipped2} = SessionGaps.measure_dir(host2)

    assert %{sessions: 1, gaps: 2, p50: 10.0, p99: 390.0, max: 390.0, over_300: 1, over_3600: 0} =
             h1

    assert %{sessions: 1, gaps: 1, p50: 4000.0, p99: 4000.0, max: 4000.0} = h2
    assert h1.over_300 + h2.over_300 == 2
    assert h1.over_3600 + h2.over_3600 == 1
    assert skipped1 + skipped2 == 1

    output = SessionGaps.report([host1, host2], & &1)

    decoded = Jason.decode!(output)
    assert decoded["skipped_lines"] == 1
    assert decoded["hosts"]["host1"]["p95"] == 390.0
    assert decoded["hosts"]["host2"]["over_3600"] == 1
  end

  @tag :tmp_dir
  test "a host with no tool calls reports zero gaps", %{tmp_dir: dir} do
    assert {%{sessions: 0, gaps: 0, p50: nil, max: nil}, 0} = SessionGaps.measure_dir(dir)
  end
end
