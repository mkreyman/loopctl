defmodule Loopctl.Knowledge.ConsolidationProposal do
  @moduledoc """
  A single numbered proposal from a nightly consolidation run (#584, #605, #608).

  Each proposal names the articles involved, carries a QUOTED excerpt from each as
  evidence, and states what it would do. The pass REPORTS both classes below and
  APPLIES exactly one — a `:duplicate_capture` group that two consecutive reports
  agree on has its losers UNPUBLISHED (reversible; never archived). There is no human
  approve/reject stage and there will not be one (#605 supersedes #594).

  ## Classes

  - `:duplicate_capture` — the same material captured twice. Two signals feed it, and
    BOTH are the same lower/strip-punctuation normalization: titles that collide once
    punctuation and case are normalized away, and `idempotency_key`s that collide under
    that normalization while differing VERBATIM (the tag-format drift of #583, which the
    novelty scorer does not catch because novelty scoring and idempotency are separate
    paths). It is deliberately NOT a `(source_type, source_id)` match: `source_id` is not
    per-article unique (#137 — that is why `idempotency_key` exists as its own column), so
    a shared source is not evidence of a duplicate capture.
  - `:generic_title` — a placeholder title ("Untitled Document", "New Article", …).
    These collide on the per-tenant active-title uniqueness and block hub creation.
  - `:contradiction_candidate` — RETIRED (#605), historical rows only. Was a SYSTEM-flagged
    (`auto_generated`) `potential_conflict` link between two PUBLISHED articles with no
    `conflict_resolutions` verdict yet.
  - `:stale_entry` — RETIRED (#605), historical rows only. Was an article past the lint
    staleness threshold, never reconciled.

  ## Review state resets on every machine re-run

  `review_status` / `reviewed_by` / `reviewed_at` are VESTIGIAL human-judgment columns —
  nothing reads them to decide anything, and no endpoint writes them. The nightly pass
  upserts proposals by `(report_id, fingerprint)` and resets all three in the SAME
  `on_conflict` clause. A re-derived proposal is a NEW machine claim: carrying an
  earlier `approved` across it would let refreshed content inherit an approval nobody
  gave (the review-gate-bypass class), and would attribute the new content to a human
  who never saw it. `Loopctl.Knowledge.Consolidation` owns that clause.

  `tenant_id` is set programmatically, never cast.
  """

  use Loopctl.Schema

  @type t :: %__MODULE__{}

  # TWO of these four are RETIRED as of #605 — no longer produced by `Consolidation.analyze/2`:
  #
  # - `:contradiction_candidate`, because `KnowledgeLintWorker.judge_redundant_conflicts/1`
  #   now owns that pile and resolves it automatically (one writer per pile).
  # - `:stale_entry`, because age is not a defect signal, so the class could never earn an
  #   apply path — and `Knowledge.lint/2` already publishes stale articles on its own
  #   endpoint with a caller-chosen threshold.
  #
  # Both values STAY in this enum: reports persisted before each change carry proposals with
  # that class, and dropping a value would make `Ecto.Enum` fail to LOAD those historical
  # rows. A retired class and a deleted one are different things, and only one of them is
  # safe on a table with history.
  @classes [:duplicate_capture, :contradiction_candidate, :generic_title, :stale_entry]
  @review_statuses [:pending, :approved, :rejected]

  schema "consolidation_proposals" do
    tenant_field()
    belongs_to :report, Loopctl.Knowledge.ConsolidationReport

    field :number, :integer
    field :proposal_class, Ecto.Enum, values: @classes
    field :article_ids, {:array, :binary_id}, default: []
    field :evidence, {:array, :map}, default: []
    field :rationale, :string
    field :suggested_action, :string
    field :severity, :string, default: "info"
    field :fingerprint, :string

    field :review_status, Ecto.Enum, values: @review_statuses, default: :pending
    field :reviewed_by, :string
    field :reviewed_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @doc "The proposal classes, in the fixed order proposals are numbered in."
  @spec classes() :: [atom()]
  def classes, do: @classes

  @doc "Valid `review_status` values."
  @spec review_statuses() :: [atom()]
  def review_statuses, do: @review_statuses

  @cast_fields [
    :report_id,
    :number,
    :proposal_class,
    :article_ids,
    :evidence,
    :rationale,
    :suggested_action,
    :severity,
    :fingerprint,
    :review_status,
    :reviewed_by,
    :reviewed_at
  ]

  @doc "Changeset for a proposal. `tenant_id` is set on the struct, not cast."
  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(proposal \\ %__MODULE__{}, attrs) do
    proposal
    |> cast(attrs, @cast_fields)
    |> validate_required([
      :report_id,
      :number,
      :proposal_class,
      :rationale,
      :suggested_action,
      :fingerprint
    ])
    |> validate_length(:article_ids, min: 1)
    |> unique_constraint([:report_id, :fingerprint],
      name: :consolidation_proposals_report_fingerprint_index
    )
  end
end
