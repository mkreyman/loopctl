defmodule Loopctl.ForgeOutbox do
  @moduledoc """
  The mechanics every forge OUTBOX shares: a table of `:pending` rows, each an outward act on
  GitHub waiting to be performed with nothing held, drained by a cron worker. Two outboxes use
  it — `Loopctl.Intake.IssueClosures` (closing a reporter's issue, #805) and
  `Loopctl.Threads.IssueLinks` (linking an intake issue to its thread page, US-45.7) — and each
  keeps its own states and its own outward calls; what is here is only what they must not
  disagree about.

  A row's schema must carry `tenant_id`, `id`, `status` (with `:pending`), `attempts`,
  `next_attempt_at` and `updated_at`. Every function is on `AdminRepo` with an explicit
  `tenant_id` predicate, because a drainer is fleet-wide.

  ## Every write is a compare-and-set on `:pending`, on the tenant's own row

  That is what makes an outbox safe under two concurrent drainers and under a replay: once a
  row leaves `:pending` nothing can move it, so a late writer from an earlier attempt cannot
  resurrect it, undo it, or reset its backoff (`update_pending/5`).
  """

  import Ecto.Query

  alias Loopctl.AdminRepo

  # How many TRANSIENT attempts a row gets before it becomes a human's problem. A blip clears
  # in seconds; at the backoff below, six attempts spans about an hour and a half of wall clock
  # even when the forge says nothing about when to come back.
  #
  # An earlier version of this note claimed six attempts was "past any rate-limit window
  # GitHub applies", and that was FALSE (#826 review, H1): the backoffs then totalled about
  # half an hour, while GitHub's PRIMARY limit is hourly. A closure hitting a primary limit
  # spent all six attempts inside one window and abandoned with the reporter never told. Two
  # things fix it and both are needed — the schedule below, and `retry_after` being HONOURED
  # rather than computed and dropped (`wait_seconds/2`).
  @max_attempts 6

  # Exponential, in seconds, indexed by the attempt just made: 3m, 6m, 12m, 24m, 48m. The list
  # is one shorter than `@max_attempts` because there is no wait after the last one.
  #
  # It STARTS ABOVE THE CRON INTERVAL, and that is the other half of H1. The drainers run
  # every 120s, so the previous first two entries (60s and 120s) were not backoff at all —
  # the row was due again on the very next sweep, and a struggling forge got hit at full
  # cadence for the two attempts that matter most.
  @backoff_seconds [180, 360, 720, 1_440, 2_880]

  # The pessimistic delay `claim_attempt/3` writes BEFORE an attempt runs: what stops a
  # candidate that RAISES from sitting at the head of the oldest-first queue and being
  # re-served on every sweep.
  @in_flight_backoff_seconds 180

  # A forge reason is REMOTE DATA, and `last_error` is built from an unbounded amount of it.
  # Only its inspected form, bounded, reaches the row — bounded in CODE POINTS, because that is
  # what the tables' `char_length` CHECKs count. `String.slice/3` counts GRAPHEMES, and a
  # grapheme can be several code points, so a reason carrying emoji or combining marks passed
  # a grapheme slice and arrived at Postgres over the bound (#826 review, finding 5).
  @error_text_budget 1_900

  @doc "How many transient attempts a row gets before it is abandoned."
  @spec max_attempts() :: pos_integer()
  def max_attempts, do: @max_attempts

  @doc """
  The seconds a transient failure waits: the local backoff for the attempt just made, or the
  forge's `retry_after` when that is longer. The `max` is load-bearing both ways — the forge's
  number wins when it is longer, the local schedule when the forge asks for a token gesture.
  """
  @spec wait_seconds(non_neg_integer(), pos_integer() | nil) :: pos_integer()
  def wait_seconds(attempts_made, retry_after) do
    backoff = backoff(attempts_made)

    if is_integer(retry_after) and retry_after > backoff, do: retry_after, else: backoff
  end

  # WHICH DELAY an attempt waits, indexed from the attempt just MADE (`attempts` is 1 after the
  # first claim, so the index is one less). Zero is guarded explicitly rather than left to
  # `Enum.at/3`, which treats -1 as "from the end" and would return the LONGEST delay as the
  # shortest (#826 round 2, finding 4).
  defp backoff(attempts_made) when attempts_made <= 1, do: hd(@backoff_seconds)

  defp backoff(attempts_made),
    do: Enum.at(@backoff_seconds, attempts_made - 1, List.last(@backoff_seconds))

  @doc """
  Marks an attempt as STARTED: bumps `attempts` and schedules the next one pessimistically.
  A compare-and-set on `:pending` AND the row being DUE, pushing `next_attempt_at` forward, so
  of two drainers holding the same candidate exactly one proceeds; the other gets
  `{:error, :not_pending}`.
  """
  @spec claim_attempt(module(), Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, struct()} | {:error, :not_pending}
  def claim_attempt(schema, tenant_id, id) do
    now = DateTime.utc_now()

    update_pending(
      schema,
      tenant_id,
      id,
      [
        set: [
          next_attempt_at: DateTime.add(now, @in_flight_backoff_seconds, :second),
          updated_at: now
        ],
        inc: [attempts: 1]
      ],
      dynamic([c], is_nil(c.next_attempt_at) or c.next_attempt_at <= ^now)
    )
  end

  @doc "Stamps `field` with now on a `:pending` row."
  @spec stamp(module(), Ecto.UUID.t(), Ecto.UUID.t(), atom()) ::
          {:ok, struct()} | {:error, :not_pending}
  def stamp(schema, tenant_id, id, field) do
    now = DateTime.utc_now()
    update_pending(schema, tenant_id, id, set: [{field, now}, {:updated_at, now}])
  end

  @doc """
  Applies `updates` (an `update_all/2` keyword list) to the tenant's `:pending` row `id`, and
  `extra_predicate` too when given. `{:ok, row}` with the row as written, or
  `{:error, :not_pending}` when it was not there to write.
  """
  @spec update_pending(module(), Ecto.UUID.t(), Ecto.UUID.t(), keyword(), term()) ::
          {:ok, struct()} | {:error, :not_pending}
  def update_pending(schema, tenant_id, id, updates, extra_predicate \\ nil) do
    query =
      from c in schema,
        where: c.tenant_id == ^tenant_id and c.id == ^id and c.status == :pending,
        select: c

    query = if extra_predicate, do: where(query, ^extra_predicate), else: query

    case AdminRepo.update_all(query, updates) do
      {1, [row]} -> {:ok, row}
      {0, _none} -> {:error, :not_pending}
    end
  end

  @doc "`reason` as the text `last_error` stores: inspected, bounded in code points; nil stays nil."
  @spec error_text(term()) :: String.t() | nil
  def error_text(nil), do: nil

  def error_text(reason) do
    text = inspect(reason)
    chars = String.to_charlist(text)

    if length(chars) > @error_text_budget,
      do: chars |> Enum.take(@error_text_budget) |> List.to_string(),
      else: text
  end
end
