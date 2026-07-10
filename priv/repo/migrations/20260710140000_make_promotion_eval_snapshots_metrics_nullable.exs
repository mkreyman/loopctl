defmodule Loopctl.Repo.Migrations.MakePromotionEvalSnapshotsMetricsNullable do
  use Ecto.Migration

  # Epic 29 (Agent Memory, Part 2 / auto-promotion), US-29.5 review hardening.
  #
  # `promotion_eval_snapshots.precision` / `.recall` were created NOT NULL DEFAULT 0.0
  # (20260710120000). The review fix makes them UNDEFINED-capable:
  #   * `precision` is NULL when the compiler emitted nothing (TP+FP == 0) — undefined,
  #     NOT 0.0, so a total LLM outage cannot misfire a precision-floor alert.
  #   * `recall` is NULL only when there are no expected facts at all (TP+FN == 0).
  #
  # The 20260710120000 migration is already released, so relaxing the constraint here as
  # a SEPARATE, purely-additive migration (drop NOT NULL + drop the 0.0 default) is what
  # actually reaches an already-migrated database (dev/prod) — editing the historical
  # migration would only change fresh-DB provisioning, never a live table. Backward-
  # compatible: existing 0.0 rows stay valid; only new rows may be NULL. Nothing is
  # dropped or renamed.

  def up do
    alter table(:promotion_eval_snapshots) do
      modify :precision, :float, null: true, default: nil
      modify :recall, :float, null: true, default: nil
    end
  end

  def down do
    alter table(:promotion_eval_snapshots) do
      modify :precision, :float, null: false, default: 0.0
      modify :recall, :float, null: false, default: 0.0
    end
  end
end
