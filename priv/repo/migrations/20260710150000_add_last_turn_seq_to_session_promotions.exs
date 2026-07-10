defmodule Loopctl.Repo.Migrations.AddLastTurnSeqToSessionPromotions do
  use Ecto.Migration

  # Epic 29 (Agent Memory, Part 2 / auto-promotion), US-29.2 review hardening.
  #
  # The promotion sweep's candidate pre-filter compared a session's newest-turn time
  # (`max(inserted_at)`) STRICTLY greater than the watermark's `last_turn_inserted_at`.
  # A turn appended at the EXACT microsecond of the stored watermark tied that
  # comparison, so the sweep permanently skipped it — its durable content was never
  # promoted until a later-microsecond turn happened to arrive. `session_memories`
  # carries a strictly-monotonic `bigserial` `seq`; recording the newest promoted turn's
  # seq on the watermark lets the sweep tiebreak same-microsecond turns.
  #
  # Additive + backward-compatible: NULLABLE, no default. Existing watermark rows keep a
  # NULL `last_turn_seq`; the sweep's NULL-safe comparison treats a same-microsecond
  # match against a NULL seq as "changed" (re-enqueued ONCE, content-hash-gated and
  # therefore cheap when genuinely unchanged), after which the next upsert populates it.
  # No backfill: session turns are short-lived (TTL-pruned), so a legacy watermark's
  # referenced turn rows are usually already gone — the NULL-safe path is both correct
  # and simpler than an unreliable backfill.

  def change do
    alter table(:session_promotions) do
      add :last_turn_seq, :bigint, null: true
    end
  end
end
