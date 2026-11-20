defmodule Sample.LateTest do
  # Not async: it runs after every async module has finished.
  use Sample.Case, async: false

  test "work handed to a process another module left behind" do
    # A shard may run this file without files_test.exs.
    agent =
      :persistent_term.get(:sample_left_behind, nil) || elem(Agent.start(fn -> :ok end), 1)

    assert Agent.get(agent, fn _ -> File.read!("docs/late.md") end) == "late\n"
  end

  test "a read relative to a changed working directory" do
    assert File.cd!("docs", fn -> File.read!("reports.md") end) == "notes\n"
  end
end
