defmodule LoopctlRunner.ProcessGroupGraceTest do
  use ExUnit.Case, async: true

  alias LoopctlRunner.ProcessGroup
  import LoopctlRunner.TestSupport

  # A command that cleans up after itself on TERM, as git removes its lock files; KILL gives it
  # no chance to.
  defp tidy_on_term(marker) do
    ~s(trap 'rm -f "#{marker}"; exit 0' TERM; touch "#{marker}"; while :; do sleep 0.1; done)
  end

  test "an expired command sent TERM first cleans up before it goes" do
    marker = Path.join(tmp_dir!("grace"), "held.lock")

    assert {:error, :timeout} =
             ProcessGroup.run("/bin/sh", ["-c", tidy_on_term(marker)], 500, [],
               term_grace_ms: 2_000
             )

    refute File.exists?(marker)
  end

  test "without a grace an expired command is killed where it stands" do
    marker = Path.join(tmp_dir!("grace"), "held.lock")

    assert {:error, :timeout} = ProcessGroup.run("/bin/sh", ["-c", tidy_on_term(marker)], 500)
    assert File.exists?(marker)
  end
end
