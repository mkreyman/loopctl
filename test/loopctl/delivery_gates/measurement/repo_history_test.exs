defmodule Loopctl.DeliveryGates.Measurement.RepoHistoryTest do
  use ExUnit.Case, async: true

  alias Loopctl.DeliveryGates.Measurement.RepoHistory

  # The runner is injected, so nothing here shells out and no fixture repository is needed.
  # No tenant either: the harness is pure of the database.

  @sha String.duplicate("a", 40)
  @parent String.duplicate("b", 40)

  defp runner(responses) do
    fn args ->
      key = key(args)

      case Map.fetch(responses, key) do
        {:ok, {:error, _reason} = error} -> error
        {:ok, output} -> {:ok, output}
        :error -> flunk("the harness ran an unexpected git command: #{inspect(args)}")
      end
    end
  end

  # The WHOLE pin list is asserted in the key, not just its first element, so dropping ANY pin is
  # an unexpected command rather than a silently different answer. Pinning only the algorithm was
  # the gap: `--indent-heuristic` and `--no-show-signature` could both be removed with the suite
  # green, which is exactly the partial-pinning shape that let a meta key be dropped unnoticed a
  # round earlier.
  #
  # `-M` so the diffstat and content reads agree with the name-status read under
  # `diff.renames=false`; `--diff-algorithm` and `--indent-heuristic` because both decide which
  # lines a hunk contains, and so move the oracle's input AND the numstat counts;
  # `--no-show-signature` because `log.showSignature=true` prepends signature lines and
  # `header/3`'s NUL-delimited format then mis-splits.
  @diff_pins ["--diff-algorithm=myers", "--indent-heuristic"]
  @log_pins ["--no-show-signature"]

  defp key(["log", "-1"] ++ @log_pins ++ _rest), do: :header
  defp key(["log", "--first-parent", _format] ++ @log_pins ++ rest), do: {:log, List.last(rest)}
  defp key(["diff", "--name-status", "-M"] ++ @diff_pins ++ _rest), do: :name_status
  defp key(["diff", "--numstat", "-M"] ++ @diff_pins ++ _rest), do: :numstat
  defp key(["diff", "--unified=0", "-M"] ++ @diff_pins ++ _rest), do: :content
  defp key(["ls-tree", "-r", "--name-only", "-z", @sha]), do: :head_files
  defp key(["ls-tree", "-r", "--name-only", "-z", @parent]), do: :base_files
  defp key(args), do: args

  defp responses(overrides \\ %{}) do
    Map.merge(
      %{
        header: "#{@parent}\0" <> "1788600000\0" <> "A synthetic change (#42)",
        name_status: "M\0lib/app/accounts/user.ex\0",
        numstat: "3\t1\tlib/app/accounts/user.ex\n",
        content: """
        diff --git a/lib/app/accounts/user.ex b/lib/app/accounts/user.ex
        --- a/lib/app/accounts/user.ex
        +++ b/lib/app/accounts/user.ex
        @@ -1,2 +1,2 @@ def changeset(user, attrs) do
        -  field :name
        +  field :full_name
           unchanged context
        """,
        head_files: "lib/app/accounts/user.ex\0README.md\0",
        base_files: "lib/app/accounts/user.ex\0"
      },
      overrides
    )
  end

  describe "change/3" do
    test "reads one change into the shape both gates take" do
      assert {:ok, change} =
               RepoHistory.change("/repo", @sha, runner: runner(responses()))

      assert change.sha == @sha
      assert change.parent_sha == @parent
      assert change.pr_number == 42
      assert change.subject == "A synthetic change (#42)"
      assert change.committed_at == DateTime.from_unix!(1_788_600_000)
      assert change.diff == "M\0lib/app/accounts/user.ex\0"
      assert change.diffstat == %{files: 1, changed_lines: 4}
      assert change.head_files == ["lib/app/accounts/user.ex", "README.md"]
      assert change.base_files == ["lib/app/accounts/user.ex"]
    end

    test "content is the changed lines only — no paths, no context, no hunk header" do
      assert {:ok, change} = RepoHistory.change("/repo", @sha, runner: runner(responses()))

      assert change.content == "  field :name\n  field :full_name"
      refute change.content =~ "lib/app/accounts/user.ex"
      refute change.content =~ "unchanged context"
      refute change.content =~ "@@"
    end

    test "content?: false skips the content read entirely" do
      responses = Map.delete(responses(), :content)

      assert {:ok, %{content: nil}} =
               RepoHistory.change("/repo", @sha, runner: runner(responses), content?: false)
    end
  end

  describe "change/3 refuses rather than guesses" do
    test "a commit with no parent is :root_commit, not an empty diff" do
      responses = responses(%{header: "\0" <> "1788600000\0" <> "Initial commit"})

      assert {:error, {@sha, :root_commit}} =
               RepoHistory.change("/repo", @sha, runner: runner(responses))
    end

    test "a git command that failed is reported with its reason, tagged by sha" do
      responses = responses(%{name_status: {:error, {:git_failed, 128, "bad object"}}})

      assert {:error, {@sha, {:git_failed, 128, "bad object"}}} =
               RepoHistory.change("/repo", @sha, runner: runner(responses))
    end

    test "an unreadable header is an error, never a defaulted subject or date" do
      assert {:error, {@sha, {:unreadable_header, _shape}}} =
               RepoHistory.change("/repo", @sha, runner: runner(responses(%{header: "garbage"})))
    end

    test "a non-numeric timestamp is an error" do
      responses = responses(%{header: "#{@parent}\0not-a-time\0Subject"})

      assert {:error, {@sha, {:unreadable_header, _shape}}} =
               RepoHistory.change("/repo", @sha, runner: runner(responses))
    end
  end

  describe "diffstat/1" do
    test "sums added and removed lines across files" do
      numstat = "3\t1\ta.ex\n10\t0\tb.ex\n"

      assert RepoHistory.diffstat(numstat) == %{files: 2, changed_lines: 14}
    end

    test "a BINARY file counts as a file and contributes no lines" do
      # `-\t-\tpath` is git's binary marker. Counting it as zero FILES would shrink the size
      # bound around a change nobody can read.
      assert RepoHistory.diffstat("-\t-\tlogo.png\n") == %{files: 1, changed_lines: 0}
    end

    test "an empty numstat is an empty diffstat" do
      assert RepoHistory.diffstat("") == %{files: 0, changed_lines: 0}
    end
  end

  describe "pr_number/1" do
    test "reads a squash-merge subject's trailing number" do
      assert RepoHistory.pr_number("Fix the rounding (#1411)") == 1411
    end

    test "a number that is not at the end is not the pull request" do
      assert RepoHistory.pr_number("Fix (#12) the rounding") == nil
    end

    test "no number is nil, never a guess" do
      assert RepoHistory.pr_number("Fix the rounding") == nil
      assert RepoHistory.pr_number(nil) == nil
    end
  end

  describe "shas/2" do
    test "splits the log output, newest first" do
      responses = %{{:log, "HEAD"} => "#{@sha}\n#{@parent}\n"}

      assert {:ok, [@sha, @parent]} = RepoHistory.shas("/repo", runner: runner(responses))
    end

    test "an empty window is an empty list — the caller decides whether that is an error" do
      assert {:ok, []} = RepoHistory.shas("/repo", runner: runner(%{{:log, "HEAD"} => ""}))
    end

    test ":head runs the window back from a PINNED commit, not from whatever HEAD is" do
      # A checkout is not a fixed corpus. The target's HEAD advanced under this harness between
      # two runs on 2026-09-13 and the corpus silently grew by 23 changes, which is what makes a
      # pinned tip the difference between a comparison and a coincidence.
      responses = %{{:log, @parent} => "#{@parent}\n"}

      assert {:ok, [@parent]} =
               RepoHistory.shas("/repo", runner: runner(responses), head: @parent)
    end
  end
end
