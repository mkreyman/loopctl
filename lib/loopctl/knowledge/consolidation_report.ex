defmodule Loopctl.Knowledge.ConsolidationReport do
  @moduledoc """
  One nightly consolidation ("dream") run for a tenant, on a UTC day (#584 stage 1).

  The run is REPORT-ONLY: it writes this row and its `ConsolidationProposal` children
  and nothing else — no `articles`, `article_links` or `conflict_resolutions` write.

  ## Denominators (state them, do not infer them — #582/#1faa4808)

  - `corpus_size` — PUBLISHED articles owned by this tenant in the scanned scope at
    scan time. Draft/archived/superseded articles and the shared system canon are
    outside it, so it is NOT the tenant's total article count.
  - `proposal_count` — the TRUE, pre-cap number of proposals the pass derived across
    all four classes. It is a count of PROPOSALS, not of articles: one duplicate
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
