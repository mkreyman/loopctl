defmodule Loopctl.Knowledge.ConsolidationReport do
  @moduledoc """
  One nightly consolidation ("dream") run for a tenant, on a UTC day (#584, #605).

  THIS ROW is a record of what the run proposed, and the run writes it plus its
  `ConsolidationProposal` children. The run itself is no longer report-only: since #608 it
  also UNPUBLISHES the losers of each `:duplicate_capture` group that this report and the
  previous one both propose (`Consolidation.apply_confirmed_duplicates/2`). That is its only
  `articles` write, it is an unpublish and never an archive, and it still writes no
  `article_links` and no `conflict_resolutions`.

  Nothing here records the apply: the counts below are what was PROPOSED, and a proposal in
  this report may or may not have been acted on tonight depending on whether last night's
  report agreed. The apply's own tally goes to the worker's `knowledge.lint_completed` audit
  event, as `consolidation.duplicates_unpublished` / `consolidation.duplicate_groups_skipped`.

  ## Denominators (state them, do not infer them — #582/#1faa4808)

  - `corpus_size` — PUBLISHED articles owned by this tenant in the scanned scope at
    scan time. Draft/archived/superseded articles and the shared system canon are
    outside it, so it is NOT the tenant's total article count.
  - `proposal_count` — the TRUE, pre-cap number of proposals the pass derived across
    every class it still PRODUCES (two of the four enum values are retired and are
    never counted here). It is a count of PROPOSALS, not of articles: one duplicate
    group of three articles is one proposal, and one article can appear in several
    proposals of different classes.
  - `persisted_count` — how many proposal ROWS this report actually carries. It is
    lower than `proposal_count` exactly when a class hit `max_per_class`; `truncated`
    says which ones did.
  - `proposals_by_class` — per-class TRUE pre-cap counts, same unit as
    `proposal_count`, keyed by the class strings in
    `Loopctl.Knowledge.ConsolidationProposal.classes/0`.

  `tenant_id` is set programmatically, never cast.
  """

  use Loopctl.Schema

  @type t :: %__MODULE__{}

  schema "consolidation_reports" do
    tenant_field()

    field :day, :date
    field :generated_at, :utc_datetime_usec
    field :corpus_size, :integer, default: 0
    field :proposal_count, :integer, default: 0
    field :persisted_count, :integer, default: 0
    field :proposals_by_class, :map, default: %{}
    field :truncated, :map, default: %{}
    field :max_per_class, :integer

    has_many :proposals, Loopctl.Knowledge.ConsolidationProposal, foreign_key: :report_id

    timestamps(type: :utc_datetime_usec)
  end

  @cast_fields [
    :day,
    :generated_at,
    :corpus_size,
    :proposal_count,
    :persisted_count,
    :proposals_by_class,
    :truncated,
    :max_per_class
  ]

  @doc "Changeset for a consolidation report. `tenant_id` is set on the struct, not cast."
  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(report \\ %__MODULE__{}, attrs) do
    report
    |> cast(attrs, @cast_fields)
    |> validate_required([:day, :generated_at, :max_per_class])
    |> unique_constraint([:tenant_id, :day], name: :consolidation_reports_tenant_day_index)
  end
end
