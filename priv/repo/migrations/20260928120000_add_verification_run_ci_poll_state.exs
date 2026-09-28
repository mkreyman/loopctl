defmodule Loopctl.Repo.Migrations.AddVerificationRunCiPollState do
  @moduledoc """
  US-26.4.6: what story verification must carry from one poll of a run to the next.

  - `resolved_commit_sha` — the FULL id of an abbreviated `commit_sha`, resolved once through
    the forge and reused by every later poll of the run (AC-26.4.6.7). NULL until resolved,
    and for a run recorded with a full id, which needs no resolution.
  - `ci_forge_faults` — transient forge faults IN A ROW. A run waiting on an unreachable forge
    snoozes, and a snoozed Oban job keeps its args, so the count has to live on the run: past
    the merge gate's consecutive-fault bound the run records `forge_unavailable` rather than
    polling for ever (AC-26.4.6.5). Any answered read resets it.

  Both nullable-safe for existing rows: NOT NULL DEFAULT 0 fills the counter, and no run ever
  needed the SHA column before. No RLS change: the table's policy covers new columns.
  """

  use Ecto.Migration

  def change do
    alter table(:verification_runs) do
      add :resolved_commit_sha, :text
      add :ci_forge_faults, :integer, null: false, default: 0
    end
  end
end
