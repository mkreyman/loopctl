defmodule LoopctlRunner.TraceTest do
  use ExUnit.Case, async: true

  alias LoopctlRunner.Trace
  import LoopctlRunner.TestSupport

  setup do
    {:ok, path: Path.join(tmp_dir!("trace"), "trace.ndjson")}
  end

  @run_id "5f0c2d8e-7a41-4b3e-9c1d-2e3f4a5b6c7d"

  test "events are gapless, parent-linked NDJSON in the contract's RunnerTraceEvent shape", %{
    path: path
  } do
    {:ok, trace} = Trace.start_link(path, @run_id)
    root = Trace.emit(trace, "run.started", nil, %{"a" => 1})
    child = Trace.emit(trace, "session.started", root)
    Trace.emit(trace, "claude.assistant", child, %{"blocks" => ["text"]})
    Trace.close(trace)

    assert {:ok, events} = Trace.read(path)
    assert Enum.map(events, & &1["seq"]) == [0, 1, 2]
    assert Enum.map(events, & &1["event_id"]) == ["0", "1", "2"]
    assert Enum.map(events, & &1["parent"]) == [nil, "0", "1"]
    assert Enum.all?(events, &(&1["run_id"] == @run_id and is_binary(&1["ts"])))
    assert Enum.all?(events, &(LoopctlRunner.Contract.validate("RunnerTraceEvent", &1) == :ok))
    assert length(String.split(File.read!(path), "\n", trim: true)) == 3
  end

  test "reopening continues the sequence instead of restarting it", %{path: path} do
    {:ok, first} = Trace.start_link(path, @run_id)
    Trace.emit(first, "run.started", nil)
    Trace.close(first)

    {:ok, second} = Trace.start_link(path, @run_id)
    assert Trace.emit(second, "run.reaped", 0) == 1
    Trace.close(second)
    assert Trace.last_seq(path) == 1
  end

  test "tree/1 rebuilds nesting from parent links" do
    events = [
      %{"seq" => 0, "event_id" => "0", "parent" => nil, "type" => "run.started"},
      %{"seq" => 1, "event_id" => "1", "parent" => "0", "type" => "session.started"},
      %{"seq" => 2, "event_id" => "2", "parent" => "1", "type" => "claude.tool_use"},
      %{"seq" => 3, "event_id" => "3", "parent" => "2", "type" => "claude.assistant"},
      %{"seq" => 4, "event_id" => "4", "parent" => "0", "type" => "run.finished"}
    ]

    assert {:ok, [root]} = Trace.tree(events)
    assert root.event["seq"] == 0
    assert Enum.map(root.children, & &1.event["seq"]) == [1, 4]
    [session, _] = root.children
    assert [%{event: %{"seq" => 2}, children: [%{event: %{"seq" => 3}}]}] = session.children
  end

  test "a trace written before event_id existed still rebuilds, even with new lines appended",
       %{path: path} do
    # The old shape, then a line in the new shape appended (as the reaper would).
    File.write!(path, """
    {"run_id":"legacy-run","seq":0,"parent":null,"ts":"2026-09-12T00:00:00Z","type":"run.started","data":{}}
    {"run_id":"legacy-run","seq":1,"parent":0,"ts":"2026-09-12T00:00:01Z","type":"session.started","data":{}}
    """)

    {:ok, trace} = Trace.start_link(path, "legacy-run")
    Trace.emit(trace, "run.reaped", 0)
    Trace.close(trace)

    assert {:ok, events} = Trace.read(path)
    assert Enum.map(events, & &1["event_id"]) == ["0", "1", "2"]
    assert {:ok, [root]} = Trace.tree(events)
    assert Enum.map(root.children, & &1.event["type"]) == ["session.started", "run.reaped"]
  end

  test "tree/1 reports a dangling parent instead of inventing a root" do
    assert {:error, {:dangling_parent, %{"seq" => 1}}} =
             Trace.tree([
               %{"seq" => 0, "event_id" => "0", "parent" => nil, "type" => "run.started"},
               %{"seq" => 1, "event_id" => "1", "parent" => "9", "type" => "claude.assistant"}
             ])
  end
end
