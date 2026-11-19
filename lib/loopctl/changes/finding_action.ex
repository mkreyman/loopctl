defmodule Loopctl.Changes.FindingAction do
  @moduledoc """
  Schema for `chg_finding_actions` (US-51.1): the outbox row for one outward act a finding
  needs on GitHub — `:open` its issue, `:close` it after a quiet period, `:reopen` it when the
  fix did not hold, `:escalate` it to a person.

  One row per `(finding_id, action, generation)`, the generation being the finding's
  `fix_attempts` when the act was decided, so a sweep that runs twice decides each act once.
  `Loopctl.Workers.ChgFindingActionWorker` performs it later with nothing held, through
  `Loopctl.Changes.FindingFiler`, exactly as `change_revert_issues` is drained.

  `story_id` is always nil. It is here because `Loopctl.ForgeOutbox.drain/4` logs it for
  every outbox row.

  Every field is set by `Loopctl.Changes.Findings`; nothing is cast from a request.
  """

  use Loopctl.Schema

  @type t :: %__MODULE__{}

  @actions [:open, :close, :reopen, :escalate]
  @statuses [:pending, :done, :abandoned]

  schema "chg_finding_actions" do
    tenant_field()
    field :finding_id, :binary_id
    field :source_id, :binary_id
    field :story_id, :binary_id, virtual: true

    field :action, Ecto.Enum, values: @actions
    field :generation, :integer
    field :cycle, :integer, default: 0

    field :repo_full_name, :string
    field :title, :string
    field :body, :string
    field :issue_number, :integer

    field :status, Ecto.Enum, values: @statuses, default: :pending
    field :done_at, :utc_datetime_usec
    field :attempts, :integer, default: 0
    field :next_attempt_at, :utc_datetime_usec
    field :last_error, :string
    field :abandoned_reason, :string

    timestamps()
  end

  @doc "The outward acts."
  @spec actions() :: [atom()]
  def actions, do: @actions
end
