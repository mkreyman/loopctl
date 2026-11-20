defmodule ChgAdapter.RunnerTest do
  use ExUnit.Case, async: true

  alias ChgAdapter.Runner

  @pass %{id: "test/a_test.exs:3", status: "pass", ms: 1}

  test "a path that reported nothing after a clean run ran no tests: skip" do
    assert Runner.missing(["test/a_test.exs", "test/b_test.exs"], [@pass], 0, false) ==
             [%{id: "test/b_test.exs", status: "skip", ms: 0}]
  end

  test "a failed run with no failing result reports the silent paths as errors" do
    assert Runner.missing(["test/a_test.exs", "test/b_test.exs"], [@pass], 1, false) ==
             [%{id: "test/b_test.exs", status: "error", ms: 0}]
  end

  test "a failed run whose every path reported still gets an error, so status and document agree" do
    assert [%{status: "error"}] = Runner.missing(["test/a_test.exs"], [@pass], 1, false)
  end

  test "a run never reports zero results unless empty is allowed" do
    assert [%{status: "skip"}] = Runner.missing([], [], 0, false)
    assert Runner.missing([], [], 0, true) == []
  end
end
