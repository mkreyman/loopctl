defmodule Loopctl.TokenUsage.CostSummary do
  @moduledoc """
  Schema for the `cost_summaries` table.

  Stores aggregated cost data for a given scope (agent, epic, project, story)
  over a date range. The rollup worker computes these summaries daily and
  upserts them using the composite unique index on
  `(tenant_id, scope_type, scope_id, period_start)`.

  ## Fields

  - `scope_type` -- `:agent`, `:epic`, `:project`, or `:story`
  - `scope_id` -- UUID of the scoped entity
  - `period_start` -- start date of the aggregation period
  - `period_end` -- end date of the aggregation period
  - `total_input_tokens` -- sum of input tokens in the period
  - `total_output_tokens` -- sum of output tokens in the period
  - `total_cost_millicents` -- sum of cost in millicents in the period
  - `report_count` -- number of token usage reports aggregated
  - `model_breakdown` -- per-model per-phase JSONB breakdown
  - `avg_cost_per_story_millicents` -- average cost per story (nullable)
  """

  use Loopctl.Schema

  @type t :: %__MODULE__{}

  @scope_types [:agent, :epic, :project, :story]

  @derive {Jason.Encoder,
           only: [
             :id,
             :tenant_id,
             :scope_type,
             :scope_id,
             :period_start,
             :period_end,
             :total_input_tokens,
             :total_output_tokens,
             :total_cost_millicents,
             :report_count,
             :model_breakdown,
             :avg_cost_per_story_millicents,
             :stale,
             :inserted_at,
             :updated_at
           ]}

  schema "cost_summaries" do
    tenant_field()

    field :scope_type, Ecto.Enum, values: @scope_types
    field :scope_id, :binary_id
    field :period_start, :date
    field :period_end, :date
    field :total_input_tokens, :integer, default: 0
    field :total_output_tokens, :integer, default: 0
    field :total_cost_millicents, :integer, default: 0
    field :report_count, :integer, default: 0
    field :model_breakdown, :map, default: %{}
    field :avg_cost_per_story_millicents, :integer
    field :stale, :boolean, default: false

    timestamps()
  end

  @doc """
  Changeset for creating or updating a cost summary.

  The `tenant_id` is set programmatically and must not be in cast.
  """
  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(summary \\ %__MODULE__{}, attrs) do
    summary
    |> cast(attrs, [
      :scope_type,
      :scope_id,
      :period_start,
      :period_end,
      :total_input_tokens,
      :total_output_tokens,
      :total_cost_millicents,
      :report_count,
      :model_breakdown,
      :avg_cost_per_story_millicents,
      :stale
    ])
    |> validate_required([
      :scope_type,
      :scope_id,
      :period_start,
      :period_end
    ])
    |> validate_inclusion(:scope_type, @scope_types)
    |> validate_number(:report_count, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:tenant_id)
    |> unique_constraint([:tenant_id, :scope_type, :scope_id, :period_start],
      name: :cost_summaries_tenant_scope_period_idx,
      message: "summary already exists for this scope and period"
    )
  end
end
