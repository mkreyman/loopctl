defmodule Loopctl.CiScaleNightlyCronTest do
  @moduledoc """
  The scale-nightly matrix runs on MANUAL DISPATCH ONLY. This guard fails the build if a
  scheduled trigger comes back.

  14 jobs, each seeding ~80k committed rows, serially on the single self-hosted runner,
  where they queue AHEAD of ordinary PR checks. The repo owner's decision is that this
  matrix carries no cron at all: it is a prod-scale PROOF you invoke for a
  query/index/corpus-shape change — which is also what US-27.5 AC-27.5.3 specified ("it is
  documented how to run it before merging a Theme 2/3/4 PR"). The nightly cron was never
  part of that story; it was added when the job was implemented, and the job comment then
  described the implementation back as though it were the requirement.

  This test exists because that decision is one a later reader will be tempted to reverse
  on a generic "don't remove a safety net" reflex — an enhanced review of the very commit
  that removed the cron proposed re-adding it as a weekly one. Re-arming it is a legitimate
  thing to DECIDE; it is not a legitimate thing to slip in as a YAML line nobody diffs.
  Failing the build turns it back into a conversation.

  **Known consequence, asserted deliberately rather than hidden.** With no schedule,
  nothing runs this gate automatically, so drift that no PR touches — a Postgres/pgvector
  upgrade, an ANALYZE shift, a migration that fails to build an HNSW index — is not caught
  until somebody dispatches it. Dispatch the matrix after any such infrastructure change.
  That trade is the point of this guard, not an argument against it.

  Same class as the matrix/tagged-file set-equality guard in
  `test/loopctl/knowledge/scale_verification_runbook_test.exs`.
  """
  use ExUnit.Case, async: true

  @ci ".github/workflows/ci.yml"

  test "the scale-nightly job's condition does not reference a schedule" do
    condition = scale_nightly_if()

    refute condition =~ "schedule",
           """
           The scale-nightly job's `if:` now references a schedule:

               #{condition}

           This matrix is manual-dispatch-only by the repo owner's decision — it holds the
           one self-hosted runner and queues ahead of ordinary PR checks. If a scheduled
           run is genuinely wanted again, agree it with the owner and update this test in
           the SAME commit, recording the reason.
           """

    assert condition =~ "workflow_dispatch",
           "scale-nightly must still be reachable by `gh workflow run CI --ref <branch>`, " <>
             "which is the enforced pre-merge step for a Theme-2/3/4 change; got: #{condition}"
  end

  test "the workflow declares exactly the one 02:00 cron the ORDINARY jobs run on" do
    assert scheduled_crons() == ["0 2 * * *"],
           """
           Expected exactly one cron in #{@ci} — "0 2 * * *", which drives the ordinary CI
           jobs — but found: #{inspect(scheduled_crons())}.

           A second cron is how a scheduled scale run comes back: a job `if:` can match one
           specific schedule string, so an added cron plus one clause re-arms the matrix
           while every other job's behaviour looks untouched.
           """
  end

  defp scheduled_crons do
    ~r/^\s*- cron:\s*"([^"]+)"/m
    |> Regex.scan(File.read!(@ci))
    |> Enum.map(fn [_line, cron] -> cron end)
  end

  # Scoped to the scale-nightly job block (its keys are indented deeper than the 2-space
  # job key), so an `if:` belonging to any other job can neither satisfy nor break this.
  defp scale_nightly_if do
    lines = @ci |> File.read!() |> String.split("\n")
    start = Enum.find_index(lines, &(&1 =~ ~r/^  scale-nightly:\s*$/))

    refute is_nil(start), "#{@ci} must declare the scale-nightly job"

    block =
      lines
      |> Enum.drop(start + 1)
      |> Enum.take_while(&(not (&1 =~ ~r/^  \S/)))
      |> Enum.join("\n")

    case Regex.run(~r/^\s*if:\s*(.+)$/m, block) do
      [_line, condition] ->
        condition

      # Non-vacuity: no `if:` at all means the job runs on EVERY push and pull_request —
      # far worse than any cron — so this is a failure, not a pass.
      nil ->
        flunk(
          "scale-nightly declares no `if:` condition, so the 14-job 80k matrix would run " <>
            "on every push and PR. It must be gated to workflow_dispatch."
        )
    end
  end
end
