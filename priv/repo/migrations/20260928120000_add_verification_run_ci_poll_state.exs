defmodule Loopctl.Repo.Migrations.AddVerificationRunCiPollState do
  @moduledoc """
  US-26.4.6: what story verification must carry from one poll of a run to the next.

  - `resolved_commit_sha` — the FULL id of an abbreviated `commit_sha`, resolved once through
    the forge and reused by every later poll of the run (AC-26.4.6.7). NULL until resolved,
    and for a run recorded with a full id, which needs no resolution.
  - `ci_forge_faults` — transient forge faults IN A ROW. A run waiting on an unreachable forge
    snoozes, and a snoozed Oban job keeps its args, so the count has to live on the run: past
    the merge gate's consecutive-fault bound the run records `forge_unavailable` rather than
    polling for ever (AC-26.4.6.5). Every poll that ends in a transient fault counts one,
    whichever read faulted; only a poll that ends in a CI answer (a pending check) resets it to
    0 — not a read answered earlier in a faulting poll, and not resolving an abbreviated SHA —
    and contention in loopctl's own database neither counts nor resets it.
  - `ci_definition_checked_at` — when this run's commit passed the change check (its
    three-dot diff with the base is not empty and touches no CI definition), for a story the
    merge gate has not already compared. The check runs ONCE per run: a merge landing during
    the run's CI wait empties that diff, and must not turn a commit already checked into a
    refused one (AC-26.4.6.3). NULL until the check passes.

  All safe for existing rows: NOT NULL DEFAULT 0 fills the counter, and no run ever needed the
  SHA or the timestamp column before. No RLS change: the table's policy covers new columns.
  """

  use Ecto.Migration

  def change do
    alter table(:verification_runs) do
      add :resolved_commit_sha, :text
      add :ci_forge_faults, :integer, null: false, default: 0
      add :ci_definition_checked_at, :utc_datetime_usec
    end
  end
end
