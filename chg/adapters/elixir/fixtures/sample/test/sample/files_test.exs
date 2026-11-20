defmodule Sample.FilesTest do
  use Sample.Case, async: true

  # An unnamed process this module leaves behind, which a later module hands work to.
  setup_all do
    {:ok, agent} = Agent.start(fn -> :ok end)
    :persistent_term.put(:sample_left_behind, agent)
    :ok
  end
  # A directory listed while this file compiles.
  @stories Path.wildcard("docs/stories/*.json")
  test "stories", do: assert(@stories == ["docs/stories/a.json"])
  test "notes", do: assert(File.read!("docs/reports.md") == "notes\n")
  test "a subprocess", do: assert({_, 0} = System.cmd("true", []))
end
