defmodule Loopctl.Repo.Migrations.QuarantineDeadVerificationBacklog do
  use Ecto.Migration

  @moduledoc false
  # US-36.1 (review, low): one-time quarantine of the pre-existing `:verification`
  # backlog at the cutover where the previously-dead queue registers a consumer.
  #
  # Since Epic 26, `Loopctl.Verification.create_run_and_enqueue/3` has atomically
  # inserted a `pending` run + an `available` Oban job on `queue: :verification`, but
  # nothing consumed that queue (it was never in the registered queues list). Those
  # jobs accumulated (Oban's Pruner prunes only TERMINAL jobs, so an `available`
  # backlog is never pruned). US-36.1 registers the queue — the moment its consumer
  # starts, Oban would drain that ENTIRE historical backlog at once: a burst of live
  # GitHub Actions API calls and, on CI-unavailable, `TestRunner` repo clones + suite
  # runs against long-stale SHAs. The worker's runtime age gate skips runs older than
  # 24h, but runs enqueued in the <24h window right before deploy would still fire.
  #
  # Migrations run BEFORE the app (and thus Oban) boots, so cancelling the non-terminal
  # backlog here means the freshly-registered consumer starts from a clean slate and
  # drains NOTHING historical — only genuinely new runs (enqueued post-deploy by the
  # live `POST /stories/:id/verifications` action) execute. Any historical run that
  # genuinely still warrants verification is re-triggerable through that live path.
  # The runtime age gate remains as defense-in-depth for any future re-accumulation.
  #
  # Scope is deliberately narrow and safe: only NON-TERMINAL, NON-EXECUTING jobs
  # (`available` / `scheduled` / `retryable`) are cancelled — never a running job
  # (none exist for a dead queue) and never an already-terminal one. Their orphaned
  # `pending` runs are retired with the dedicated `"skipped"` disposition (US-36.1) —
  # a deliberate non-execution, NOT an `"error"` (which would imply a genuine failure).

  def up do
    # 1. Retire the orphaned `pending` runs whose only consumer was a non-terminal
    #    backlog job, as "skipped" — so they don't linger as perpetual "pending".
    execute("""
    UPDATE verification_runs vr
    SET status = 'skipped',
        completed_at = timezone('utc', now()),
        ac_results = coalesce(vr.ac_results, '{}'::jsonb)
                     || jsonb_build_object('reason', 'backlog_quarantined_at_cutover')
    FROM oban_jobs oj
    WHERE oj.queue = 'verification'
      AND oj.state IN ('available', 'scheduled', 'retryable')
      AND vr.status = 'pending'
      AND (oj.args->>'run_id') IS NOT NULL
      AND (oj.args->>'run_id')::uuid = vr.id
    """)

    # 2. Cancel the non-terminal backlog jobs so the newly-registered consumer never
    #    drains them (state -> 'cancelled', matching Oban's own cancel semantics).
    execute("""
    UPDATE oban_jobs
    SET state = 'cancelled',
        cancelled_at = timezone('utc', now())
    WHERE queue = 'verification'
      AND state IN ('available', 'scheduled', 'retryable')
    """)
  end

  def down do
    # Irreversible by design: re-materializing the exact prior (state, run status)
    # would re-arm the very burst-drain this migration exists to prevent. A run that
    # still needs verification is re-triggerable via POST /stories/:id/verifications.
    :ok
  end
end
