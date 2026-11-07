defmodule Loopctl.Agents.TuningDraft do
  @moduledoc """
  Schema for the `spec_tuning_drafts` table (Epic 48, US-48.13): one improvement-loop run of
  one target spec in one project, and loopctl's judgement of what the runner proposed.

  NOTHING in loopctl applies a draft. A `proposed` draft is a prompt-template diff and new eval
  cases for a person to turn into a pull request; the template and the spec version change only
  when that pull request merges, and an operator then marks the draft `landed` with its URL
  (`Loopctl.Agents.Tuning.mark_landed/4`).

  `status` is loopctl's, never the runner's: `Loopctl.Agents.Tuning.decide/2` recomputes it from
  the per-case results. Every field is set programmatically by `Loopctl.Agents.Tuning`; there is
  no caller changeset, so nothing here can be mass-assigned. See the migration for the CHECKs.
  """

  use Loopctl.Schema

  @statuses [:pending, :proposed, :rejected, :landed, :superseded, :abandoned]

  @type t :: %__MODULE__{}

  schema "spec_tuning_drafts" do
    tenant_field()
    field :project_id, :binary_id
    field :dispatch_id, :binary_id
    field :target_spec_id, :string
    field :target_spec_version, :integer
    field :template_id, :string
    field :from_version, :integer
    field :to_version, :integer
    field :eval_set, :string
    field :status, Ecto.Enum, values: @statuses
    field :rejection_reasons, {:array, :string}, default: []
    field :window_since, :utc_datetime_usec
    field :window_until, :utc_datetime_usec
    field :outcome_rows, :integer
    field :input, :map
    field :new_cases, :map
    field :diff, :string
    field :current_score, :map
    field :proposed_score, :map
    field :per_case, :map
    field :pr_url, :string
    field :answered_at, :utc_datetime_usec
    field :landed_at, :utc_datetime_usec

    timestamps()
  end

  @doc "The statuses a row may carry."
  @spec statuses() :: [atom()]
  def statuses, do: @statuses
end
