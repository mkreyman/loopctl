defmodule Loopctl.Changes.RevertIssue do
  @moduledoc """
  Schema for `change_revert_issues` — the outbox row for the GitHub issue a chg revert opens
  when it reaches a story that is already `done` (US-47.4, AC-47.4.5, Epic 47 PRD §5).

  `done` is terminal by design, so the revert cannot move the story. It is appended to the
  story's history instead, and a NEW report is filed on the repository through the existing
  intake path: an issue carrying chg's failing tests, fenced as untrusted text, which intake
  then triages like any other.

  One row per revert EVENT, decided by the unique index on `(tenant_id, repo, change_id,
  event_seq)`, and written in the event's own transaction — so the intent commits with the
  event or not at all, and the webhook makes no outbound call.
  `Loopctl.Workers.ChangeRevertIssueWorker` opens the issue later with nothing held.

  ## The states

  - `:pending` — the drainer's candidate set.
  - `:opened` — the issue exists, as `issue_number`, since `opened_at`. Terminal.
  - `:abandoned` — loopctl will not open it, and `abandoned_reason` says why: the source was
    revoked or left the change protocol, the forge refused permanently, or the transient
    retries ran out. Terminal.

  Every field is set by `Loopctl.Changes.RevertIssues`; nothing is cast from a request.
  """

  use Loopctl.Schema

  @type t :: %__MODULE__{}

  @statuses [:pending, :opened, :abandoned]

  schema "change_revert_issues" do
    tenant_field()
    field :story_id, :binary_id
    field :source_id, :binary_id

    field :repo, :string
    field :change_id, :string
    field :event_seq, :integer

    field :repo_full_name, :string
    field :title, :string
    field :body, :string

    field :status, Ecto.Enum, values: @statuses, default: :pending
    field :issue_number, :integer
    field :opened_at, :utc_datetime_usec

    field :attempts, :integer, default: 0
    field :next_attempt_at, :utc_datetime_usec
    field :last_error, :string
    field :abandoned_reason, :string

    timestamps()
  end

  @doc "The row statuses."
  @spec statuses() :: [atom()]
  def statuses, do: @statuses
end
