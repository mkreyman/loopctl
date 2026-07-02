defmodule Loopctl.TokenUsage.Report do
  @moduledoc """
  Schema for the `token_usage_reports` table.

  Tracks token consumption and cost for agent work on stories.
  Each report records input/output tokens, the model used, and cost
  in millicents (1/1000 of a cent).

  ## Fields

  - `input_tokens` -- number of input tokens consumed (may be negative for corrections)
  - `output_tokens` -- number of output tokens consumed (may be negative for corrections)
  - `total_tokens` -- generated column: input_tokens + output_tokens (read-only)
  - `model_name` -- name of the LLM model used (e.g., "claude-opus-4")
  - `cost_millicents` -- cost in 1/1000 of a cent (may be negative for corrections)
  - `phase` -- work phase: planning, implementing, reviewing, other
  - `session_id` -- optional session identifier
  - `skill_version_id` -- optional FK to skill_versions
  - `metadata` -- extensible JSONB map
  - `deleted_at` -- soft-delete timestamp; nil means active (AC-21.13.1)
  - `corrects_report_id` -- FK to the original report this corrects (AC-21.13.2)
  """

  use Loopctl.Schema, soft_delete: true

  import Ecto.Query, only: [where: 3]

  @type t :: %__MODULE__{}

  @phases ~w(planning implementing reviewing other)

  @derive {Jason.Encoder,
           only: [
             :id,
             :tenant_id,
             :story_id,
             :agent_id,
             :project_id,
             :input_tokens,
             :output_tokens,
             :total_tokens,
             :model_name,
             :cost_millicents,
             :phase,
             :session_id,
             :skill_version_id,
             :metadata,
             :deleted_at,
             :corrects_report_id,
             :inserted_at,
             :updated_at
           ]}

  schema "token_usage_reports" do
    tenant_field()
    belongs_to :story, Loopctl.WorkBreakdown.Story
    belongs_to :agent, Loopctl.Agents.Agent
    belongs_to :project, Loopctl.Projects.Project
    belongs_to :skill_version, Loopctl.Skills.SkillVersion
    belongs_to :corrects_report, __MODULE__, foreign_key: :corrects_report_id

    field :input_tokens, :integer
    field :output_tokens, :integer
    field :total_tokens, :integer
    field :model_name, :string
    field :cost_millicents, :integer
    field :phase, :string, default: "other"
    field :session_id, :string
    field :metadata, :map, default: %{}
    field :deleted_at, :utc_datetime_usec

    # US-26.6.1: Extended telemetry for lazy-bastard scoring
    field :tool_call_count, :integer
    field :cot_length_tokens, :integer
    field :tests_run_count, :integer

    timestamps()
  end

  @doc """
  Changeset for creating a new token usage report.

  The `tenant_id`, `agent_id`, and `project_id` are set programmatically
  and must not be in cast.
  """
  @spec create_changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def create_changeset(report \\ %__MODULE__{}, attrs) do
    report
    |> cast(attrs, [
      :input_tokens,
      :output_tokens,
      :model_name,
      :cost_millicents,
      :phase,
      :session_id,
      :skill_version_id,
      :metadata,
      :tool_call_count,
      :cot_length_tokens,
      :tests_run_count
    ])
    |> validate_required([:input_tokens, :output_tokens, :model_name, :cost_millicents])
    |> validate_number(:input_tokens, greater_than_or_equal_to: 0)
    |> validate_number(:output_tokens, greater_than_or_equal_to: 0)
    |> validate_number(:cost_millicents, greater_than_or_equal_to: 0)
    |> validate_inclusion(:phase, @phases)
    |> validate_length(:model_name, min: 1)
    |> validate_metadata_size()
    |> foreign_key_constraint(:tenant_id)
    |> foreign_key_constraint(:story_id)
    |> foreign_key_constraint(:agent_id)
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:skill_version_id)
  end

  @doc """
  Changeset for creating a correction report.

  Corrections allow negative `input_tokens`, `output_tokens`, and
  `cost_millicents` (to subtract from the story's running total).
  The `corrects_report_id` is set programmatically.
  """
  @spec correction_changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def correction_changeset(report \\ %__MODULE__{}, attrs) do
    report
    |> cast(attrs, [
      :input_tokens,
      :output_tokens,
      :model_name,
      :cost_millicents,
      :phase,
      :session_id,
      :skill_version_id,
      :metadata,
      :tool_call_count,
      :cot_length_tokens,
      :tests_run_count
    ])
    |> validate_required([:input_tokens, :output_tokens, :model_name, :cost_millicents])
    |> validate_inclusion(:phase, @phases)
    |> validate_length(:model_name, min: 1)
    |> validate_metadata_size()
    |> foreign_key_constraint(:tenant_id)
    |> foreign_key_constraint(:story_id)
    |> foreign_key_constraint(:agent_id)
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:skill_version_id)
    |> foreign_key_constraint(:corrects_report_id)
  end

  @doc """
  Composable query builder that excludes "stranded" correction rows from any
  `token_usage_reports` aggregate/total query (tokens-04).

  A report counts toward a total only when it is NOT a correction, OR its
  referenced original is still live (present and not soft-deleted). Without
  this, a negative correction survives after its original is soft-deleted or
  expired and drives story/epic/project totals — and any derived spend/rollup —
  negative.

  This is the SINGLE reusable predicate every total-computing query pipes
  through, so no query drifts back to a bare `is_nil(deleted_at)` filter. It is
  expressed as a `where` on the FIRST query binding (a `token_usage_reports`
  row) via a correlated `EXISTS`, so it composes onto any query — with or
  without joins — without shifting positional bindings or fanning out sums.

  The correlated subquery is tenant-scoped (`o.tenant_id = r.tenant_id`) as
  defense-in-depth so it can never count against a cross-tenant original, even
  under `AdminRepo` (BYPASSRLS).

  Callers must still apply their own `is_nil(r.deleted_at)` filter; this only
  adds the correction/original consistency predicate.
  """
  @spec exclude_stranded_corrections(Ecto.Queryable.t()) :: Ecto.Query.t()
  def exclude_stranded_corrections(query) do
    where(
      query,
      [r],
      is_nil(r.corrects_report_id) or
        fragment(
          "EXISTS (SELECT 1 FROM token_usage_reports o WHERE o.id = ? AND o.tenant_id = ? AND o.deleted_at IS NULL)",
          r.corrects_report_id,
          r.tenant_id
        )
    )
  end

  @metadata_max_bytes 65_536

  defp validate_metadata_size(changeset) do
    validate_change(changeset, :metadata, fn :metadata, value ->
      if byte_size(Jason.encode!(value)) > @metadata_max_bytes,
        do: [metadata: "must be smaller than 64KB"],
        else: []
    end)
  end
end
