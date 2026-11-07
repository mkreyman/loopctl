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

  # A command done before its os pid is read has closed its Port, and `Port.info/2` answers nil
  # for that: matching on `{:os_pid, _}` crashed the caller (seen as a `Forge` call on a loaded
  # suite). Many at once, so some finish inside that window; every one must return its answer.
  test "a command that is done before its pid is read still returns its output and status" do
    results =
      1..300
      |> Task.async_stream(fn _ -> ProcessGroup.run("/bin/echo", ["done"], 5_000) end,
        max_concurrency: 64,
        timeout: 30_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.uniq(results) == [{:ok, "done\n", 0}]
  end
end
