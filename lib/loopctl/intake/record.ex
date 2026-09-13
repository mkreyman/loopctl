defmodule Loopctl.Intake.Record do
  @moduledoc """
  Schema for the `intake_records` table — one GitHub issue of one intake source, the queue
  entry triage consumes (issues #803 and #804).

  ## Untrusted fields

  Everything the REPORTER controls is stored only in a field whose name starts with
  `untrusted_`: the issue title, body, labels and author login. Those fields are DATA,
  never instruction, at every hop:

  - they are capped (`Loopctl.Intake.GithubPayload`, mirrored by the
    `intake_records_untrusted_caps` CHECK);
  - they are never copied into a story, an epic, or any field an implementer prompt is
    built from — `Loopctl.Delivery.ImplementerInput` builds from a `Story` alone;
  - any prompt that must carry them renders them through `Loopctl.Delivery.Untrusted`.

  `test/loopctl/delivery/implementer_input_test.exs` fails when an `untrusted_` field is
  read anywhere outside the intake and delivery modules that own the boundary.

  ## Structured facts

  `ticket_ref`, `ticket_id`, `ticket_priority` and `ticket_kind` are extracted from the
  HomeCareBilling issue format by strict pattern (`Loopctl.Intake.TicketFacts`), never by
  a model. Each is shape-constrained so it cannot carry prose, but each is still a
  CLAIM made by text the reporter influences.

  ## Order ambiguity

  `order_ambiguous` with `order_ambiguous_at` marks a record whose last applied delivery
  carried the same `issue.updated_at` second as the one before it but different content.
  GitHub's timestamp has one-second precision and a payload has no other ordering key, so
  the stored content may be one event behind the live issue. **Triage must re-read the live
  issue from GitHub whenever `order_ambiguous` is set** (a runner has `gh` access; loopctl
  does not). A strictly newer delivery clears it. See "Delivery order" in `Loopctl.Intake`.

  ## Escalation

  `status: :escalated` with `escalation_reasons` (`"<signal>:<field>"` strings) is set
  when `Loopctl.Delivery.InjectionDetector` or the fact extractor fires, and is never
  cleared by a later delivery: an edit that removes the injection does not un-escalate.
  """

  use Loopctl.Schema

  @type t :: %__MODULE__{}

  @statuses [:pending_triage, :escalated]

  schema "intake_records" do
    tenant_field()
    belongs_to :source, Loopctl.Intake.Source
    belongs_to :project, Loopctl.Projects.Project

    field :issue_number, :integer
    field :github_issue_id, :integer
    field :html_url, :string
    field :issue_state, :string
    field :issue_updated_at, :utc_datetime_usec

    field :untrusted_title, :string, default: ""
    field :untrusted_body, :string, default: ""
    field :untrusted_labels, {:array, :string}, default: []
    field :untrusted_author_login, :string
    field :untrusted_truncated, :boolean, default: false

    field :ticket_ref, :string
    field :ticket_id, Ecto.UUID
    field :ticket_priority, :string
    field :ticket_kind, :string

    field :status, Ecto.Enum, values: @statuses, default: :pending_triage
    field :escalation_reasons, {:array, :string}, default: []
    field :escalated_at, :utc_datetime_usec
    field :last_action, :string
    field :last_delivery_id, :string
    field :order_ambiguous, :boolean, default: false
    field :order_ambiguous_at, :utc_datetime_usec

    timestamps()
  end

  @doc "The record statuses."
  @spec statuses() :: [atom()]
  def statuses, do: @statuses

  @doc """
  Changeset applying one delivery's issue facts. Every field here is set by
  `Loopctl.Intake` from a parsed payload; there is no caller-supplied `cast`.
  """
  @spec apply_changeset(t(), map()) :: Ecto.Changeset.t()
  def apply_changeset(%__MODULE__{} = record, changes) when is_map(changes) do
    record
    |> change(changes)
    |> check_constraint(:untrusted_body, name: :intake_records_untrusted_caps)
    |> check_constraint(:ticket_ref, name: :intake_records_ticket_shape)
    |> check_constraint(:status, name: :intake_records_escalation_shape)
    |> check_constraint(:order_ambiguous, name: :intake_records_order_ambiguity_shape)
  end
end
