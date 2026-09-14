defmodule Loopctl.Intake.IssueClosure do
  @moduledoc """
  Schema for `intake_issue_closures` — loopctl's record that it closed (or will close) the
  GitHub issue a story came from (#803 §9, #805 item 1).

  One row per story, and that is the whole safety argument. Closing a reporter's issue is an
  OUTWARD act on somebody else's system: it fires the reporting system's webhook, which
  sends the reporter a resolution email. Doing it twice sends the email twice. So the
  at-most-once guarantee is a UNIQUE INDEX on `(tenant_id, story_id)` — decided by Postgres,
  not by a status check some code path can race — and the row is inserted inside the very
  transaction that writes the terminal verdict.

  ## Who owns what

  **Postgres owns whether WE closed it.** That is this row. **GitHub owns whether it IS
  closed.** Those are different facts and they can disagree — a human can close the issue
  under us — so the closer READS the issue before it acts and treats a close it did not make
  as a permanent stop rather than something to redo.

  ## The states

  - `:pending` — a verdict was reached and the issue has not been closed yet. The drainer's
    candidate set.
  - `:closed` — loopctl closed it, at `closed_at`. Terminal.
  - `:abandoned` — it will never be closed by loopctl, and `abandoned_reason` says why: a
    human closed it first, the repository or issue is gone, the token cannot write there, or
    the transient retries ran out. Terminal, and specifically NOT `:pending` — a permanent
    failure that stayed pending is a retry loop against a forge that will keep saying no.

  ## The per-step markers

  `labelled_at`, `commented_at` and `closed_at` are each written straight after their own
  forge call. They exist because the sequence is three outward calls and a crash can land
  between any two of them: with a marker per step a replay redoes at most the ONE step it
  died inside, instead of the whole sequence. The step that must never repeat — the close —
  is additionally guarded by reading the issue's live state first.

  ## Isolation

  `tenant_id` on every row, RLS enabled, and every query in `Loopctl.Intake.IssueClosures`
  carries an explicit `tenant_id` predicate as well — except the drainer's fleet-wide
  candidate read, which runs on `AdminRepo` and RESOLVES the tenant rather than assuming
  one, exactly as `Loopctl.Workers.PostDeployVerificationWorker` does.
  """

  use Loopctl.Schema

  alias Loopctl.Delivery.Resolution

  @type t :: %__MODULE__{}

  @statuses [:pending, :closed, :abandoned]

  # DERIVED from the resolution table, never restated: the verdicts whose resolution says
  # `close?: true`. `:escalated` falls out by itself — an escalated story is waiting on a
  # human, so there is nothing to record and no row to drain — and a verdict that stops
  # closing over there stops being storable here, rather than leaving an enum value the
  # closer would have to decide what to do with.
  @verdicts Enum.filter(Resolution.verdicts(), &Resolution.for_verdict(&1).close?)

  schema "intake_issue_closures" do
    tenant_field()
    field :story_id, :binary_id
    field :intake_record_id, :binary_id

    field :repo_full_name, :string
    field :issue_number, :integer

    field :verdict, Ecto.Enum, values: @verdicts
    field :status, Ecto.Enum, values: @statuses, default: :pending

    field :labelled_at, :utc_datetime_usec
    field :commented_at, :utc_datetime_usec
    field :closed_at, :utc_datetime_usec

    field :attempts, :integer, default: 0
    field :next_attempt_at, :utc_datetime_usec
    field :last_error, :string
    field :abandoned_reason, :string

    timestamps()
  end

  @doc "The closure statuses."
  @spec statuses() :: [atom()]
  def statuses, do: @statuses

  @doc """
  The verdicts that produce a closure row.

  A strict subset of `Loopctl.Delivery.Resolution.verdicts/0` — the ones whose resolution
  says `close?: true`. Derived from that module rather than restated, so a verdict that
  stops closing there stops producing rows here.
  """
  @spec verdicts() :: [Resolution.verdict()]
  def verdicts, do: @verdicts

  @doc """
  The resolution this row's verdict implies — the text and the label the close carries.

  One hop to `Loopctl.Delivery.Resolution`, which is the CONTRACT the reporting system binds
  to. Nothing here restates a label or a message.
  """
  @spec resolution(t()) :: Resolution.t()
  def resolution(%__MODULE__{verdict: verdict}), do: Resolution.for_verdict(verdict)
end
