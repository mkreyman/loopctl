defmodule Loopctl.Repo.Migrations.WidenEscalationReasonForEscaping do
  @moduledoc """
  Issue #804: the `escalation_reason` CHECK accommodates the ESCAPED form of a reason that was
  bounded at 4,000 codepoints RAW. No column type change, no backfill, no manual step — an
  existing row is already inside the wider bound by construction.

  ## Why the column bound and the published bound must differ

  `escalation_reason` is escaped before storage (`Stages.advance/4` runs it through
  `Untrusted.sanitise/1`), and escaping EXPANDS: one hidden codepoint becomes up to ten visible
  characters, `<U+10FFFF>`. So the stored string is longer than the one the caller sent, and
  the two cannot share one number.

  **The number the caller is held to must stay 4,000 on the RAW text**, and that is the whole
  reason this migration exists rather than the validator simply bounding the escaped form.
  A caller cannot predict the escaped length: it would have to implement loopctl's escape
  table to know whether its reason fits. The contract PUBLISHES `stage_max_reason_length` and
  a runner validates against it before sending, so a bound only loopctl can compute is a bound
  no client can honour — it would send a conforming message and be refused, and the escalation
  would be lost. That is the failure this whole change set exists to end, reintroduced one
  layer up.

  So: the caller is bounded on what it can measure, and the COLUMN is bounded on what it
  actually holds. 40,000 is `4_000 * 10`, the worst case where every codepoint of a
  maximum-length reason is escaped to its longest form. It is a ceiling that cannot be reached
  by a conforming caller rather than a limit anyone is expected to approach.

  Round 1 of #859's review is what found this: the validator had been moved to the escaped
  length while the controller and the contract still bounded the raw one, so a 4,000-codepoint
  reason carrying a single zero-width space passed the HTTP check and was then refused 422 by
  the context.
  """

  use Ecto.Migration

  @old "char_length(escalation_reason) BETWEEN 1 AND 4000"
  @new "char_length(escalation_reason) BETWEEN 1 AND 40000"

  @shared "char_length(worktree_path) BETWEEN 1 AND 4096 " <>
            "AND char_length(branch) BETWEEN 1 AND 255 " <>
            "AND char_length(release_id) BETWEEN 1 AND 255 "

  def up do
    drop(constraint(:story_stages, :story_stages_text_bounds))

    create(constraint(:story_stages, :story_stages_text_bounds, check: @shared <> "AND " <> @new))
  end

  def down do
    drop(constraint(:story_stages, :story_stages_text_bounds))

    create(constraint(:story_stages, :story_stages_text_bounds, check: @shared <> "AND " <> @old))
  end
end
