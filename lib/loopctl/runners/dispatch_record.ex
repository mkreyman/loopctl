defmodule Loopctl.Runners.DispatchRecord do
  @moduledoc """
  Schema for the `runner_dispatches` table — the dispatch ledger (issue #803).

  `Loopctl.Runners.dispatch/3` writes one row per `dispatch_id` BEFORE it broadcasts, so the
  identity of the outward side effect exists before the side effect does. The runner's
  `dispatch_reply` moves the row out of `sent` once (`Loopctl.Runners.DispatchLedger`), the
  first trace batch of the accepted run binds `run_id`, and `trace_acked_seq` is that run's
  contiguous trace cursor (-1 before any event is stored).

  ## Status

  - `sent` — handed to the runner's channel. Not delivered: the channel may still drop it
    (a halt, a second socket), and re-dispatching the same `dispatch_id` re-sends it.
    `pushed_at` is stamped when a channel actually pushes it, so `sent` with no `pushed_at`
    is a dispatch that never reached a socket.
  - `accepted` / `refused` — the runner's reply. Terminal for the reply; a refusal carries a
    `reason` (`RunnerContract.refusal_reasons/0`).
  - `superseded` — the claim this dispatch served has ended: the story's `claim_epoch` moved
    past this row's. Written by `Loopctl.Runners.DispatchLedger` when a reply or trace about
    the row finds that, never by the runner; a `refused` row is left refused.

  ## Capacity

  A dispatch recorded as `sent` holds one of its runner's slots (`Loopctl.Runners.Capacity`)
  until `released_at` is set. `slot_generation` names the slot currently or last held — a
  re-send of an undelivered dispatch takes a new one — and a release applies only to the
  generation it names. `reserved_at` is when that slot was taken.

  `delivery` is the reservation's ONE decision, taken under the row lock by whichever of the
  two processes a broadcast wakes gets there first: `"pushed"` (the dispatch went to a
  socket) or `"dropped"` (a channel refused to push it and gave the slot back). It is reset
  with every reservation, and `wall_clock_seconds` is refreshed when a push wins, so the
  bound `Loopctl.Runners.Capacity` applies is always the clock the session is running under.

  ## Session end (since contract 1.16.0)

  `session_ended_reason` is the runner's own account of why the session under this dispatch
  stopped, recorded once. `session_ended_digest` decides whether a later copy is the SAME
  report (answered `ok`) or a different one (refused `already_recorded`), and
  `counts_toward_retry_ceiling` says, for the two reasons that re-queue the story, whether
  that release is spent against the retry ceiling — `crashed` is, `usage_exhausted` is not.

  ## Trust boundary

  Every field is set programmatically in `Loopctl.Runners`; there is no caller changeset.

  ## Isolation

  Written only through `Loopctl.Runners.DispatchLedger` and `Loopctl.Runners.Capacity` (which
  sets `released_at`), on the RLS-enforced `Loopctl.Repo` inside `Repo.with_tenant/2`, with an
  explicit `tenant_id` predicate as well. Never written through `AdminRepo` — see
  `DispatchLedger`; `Loopctl.Workers.HealRunnerCapacityWorker` only reads a bounded candidate
  list there.
  """

  use Loopctl.Schema

  @type t :: %__MODULE__{}

  @statuses ~w(sent accepted refused superseded)

  schema "runner_dispatches" do
    tenant_field()
    field :runner_id, :binary_id
    field :dispatch_id, :binary_id
    field :story_id, :binary_id
    field :claim_epoch, :integer
    field :kind, :string
    # The branch the FIRST push named, so a retry of this dispatch cannot land on another one
    # (#846.2). NULL on every row written before that column existed.
    field :branch, :string
    field :status, :string, default: "sent"
    field :reason, :string
    field :reason_detail, :string
    field :replied_at, :utc_datetime_usec
    field :pushed_at, :utc_datetime_usec
    field :run_id, :binary_id
    field :trace_acked_seq, :integer, default: -1
    field :wall_clock_seconds, :integer
    field :released_at, :utc_datetime_usec
    field :reserved_at, :utc_datetime_usec
    field :slot_generation, :integer, default: 0
    field :delivery, :string
    # Why the session ended, as the runner reported it (`session_ended`, contract 1.16.0,
    # US-44.3). Written once, with the digest a resend is compared against, by
    # `Loopctl.Runners.DispatchLedger.record_session_end/4`; all four NULL until then.
    field :session_ended_reason, :string
    field :session_ended_digest, :string
    field :session_ended_at, :utc_datetime_usec
    field :counts_toward_retry_ceiling, :boolean

    timestamps()
  end

  @doc "Every status a ledger row can hold."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses
end
