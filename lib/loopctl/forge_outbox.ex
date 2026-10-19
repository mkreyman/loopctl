defmodule Loopctl.ForgeOutbox do
  @moduledoc """
  The mechanics every forge OUTBOX shares: a table of `:pending` rows, each an outward act on
  GitHub waiting to be performed with nothing held, drained by a cron worker. Its users are
  `Loopctl.Intake.IssueClosures` (closing a reporter's issue, #805) and
  `Loopctl.Changes.RevertIssues` (opening one for a chg revert, US-47.4), each keeping its own
  states and its own outward calls; what is here is the mechanics an outbox must get right,
  the drainer's pass over its candidates included (`drain/4`, `drain_result/2`).

  A row's schema must carry `tenant_id`, `id`, `status` (with `:pending`), `attempts`,
  `next_attempt_at` and `updated_at`. Every function is on `AdminRepo` with an explicit
  `tenant_id` predicate, because a drainer is fleet-wide.

  ## Every write is a compare-and-set on `:pending`, on the tenant's own row

  That is what makes an outbox safe under two concurrent drainers and under a replay: once a
  row leaves `:pending` nothing can move it, so a late writer from an earlier attempt cannot
  resurrect it, undo it, or reset its backoff (`update_pending/5`).
  """

  import Ecto.Query

  require Logger

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

  @doc """
  One drainer pass over `candidates`, calling `attempt` on each and returning
  `[{candidate, outcome}]` in order, where `attempt` returns `{outcome, retry_after}`.

  Stops at `deadline` (a `System.monotonic_time(:millisecond)` value), checked BEFORE each
  candidate so a run cannot start one just under its budget and finish past the cron interval,
  or at the first result carrying a `retry_after`: a rate-limited forge is a reason to stop
  asking, not to ask the rest of the batch.

  ONE CANDIDATE MAY NOT KILL THE RUN (#826 review, finding 5). An exception out of `attempt`
  would skip every remaining candidate and burn an Oban attempt — and since the candidate
  reads are oldest-first, a row that raises reliably would sit at the head of every batch, a
  fleet-wide stall caused by one row. So a raise OR AN EXIT (a `Finch` pool checkout timeout,
  a `GenServer.call` timeout and a `DBConnection` ownership failure all exit rather than
  raise; #826 round 2) costs that candidate, logged at ERROR with its identity, and is
  `:errored`. It is safe to carry on because the drainer's `claim_attempt/3` committed before
  anything outward ran: the attempt is counted and the row is scheduled forward, so a raising
  row waits its backoff like a transient failure and is still bounded by `max_attempts/0`.

  `opts`: `:label` (required), the drainer's name in its log lines; `:id_name`, the name the
  candidate's id is logged under (default `"row_id"`).
  """
  @spec drain([map()], integer(), (map() -> {atom(), pos_integer() | nil}), keyword()) ::
          [{map(), atom()}]
  def drain(candidates, deadline, attempt, opts) when is_function(attempt, 1) do
    label = Keyword.fetch!(opts, :label)
    id_name = Keyword.get(opts, :id_name, "row_id")

    candidates
    |> Enum.reduce_while([], fn row, acc ->
      if System.monotonic_time(:millisecond) >= deadline,
        do: {:halt, budget_spent(acc, label)},
        else: after_candidate(row, acc, attempt, label, id_name)
    end)
    |> Enum.reverse()
  end

  defp after_candidate(row, acc, attempt, label, id_name) do
    {outcome, retry_after} = contained(row, attempt, label, id_name)
    acc = [{row, outcome} | acc]
    if is_integer(retry_after), do: {:halt, acc}, else: {:cont, acc}
  end

  defp budget_spent(acc, label) do
    Logger.info(
      "#{label}: wall-clock budget spent after #{length(acc)} " <>
        "candidate(s); the rest are the next run's"
    )

    acc
  end

  defp contained(row, attempt, label, id_name) do
    attempt.(row)
  rescue
    error -> errored(row, label, id_name, Exception.format(:error, error, __STACKTRACE__))
  catch
    # The `:exit` clause is for the MESSAGE only — `Exception.format_exit/1` renders a pool
    # checkout timeout readably where the generic formatter does not. The catch-all below it
    # already handles exits, so removing this clause changes no behaviour; the falsifiable
    # guard is the whole `catch`, whose removal does turn the suite red.
    :exit, reason -> errored(row, label, id_name, "exit: " <> Exception.format_exit(reason))
    kind, value -> errored(row, label, id_name, Exception.format(kind, value, __STACKTRACE__))
  end

  defp errored(row, label, id_name, detail) do
    Logger.error(
      "#{label}: candidate failed, continuing with the rest of the batch: " <>
        "tenant_id=#{row.tenant_id} story_id=#{row.story_id} " <>
        "#{id_name}=#{row.id} detail=#{detail}",
      tenant_id: row.tenant_id,
      story_id: row.story_id
    )

    {:errored, nil}
  end

  @doc """
  What a drainer's `perform/1` returns for `drain/4`'s results, after logging their tally
  under `label`.

  A SYSTEMIC failure must not report as a successful job (#826 round 2, finding 2). The
  per-candidate containment is right for ONE bad row and wrong for a bad WORLD: on a
  connection-pool outage every candidate raises, each is contained, and a job that returned
  `:ok` would record a clean run — `max_attempts` never fires, nothing is discarded, nothing
  alerts. So every candidate erroring is an ERROR for the job, which Oban retries and
  eventually discards where it can be seen. A run with some errors and some progress stays
  `:ok`: that is the one-bad-row case, and the row's own attempt counter bounds it.
  """
  @spec drain_result([{map(), atom()}], String.t()) ::
          :ok | {:error, {:all_candidates_errored, pos_integer()}}
  def drain_result(results, label) do
    tally = Enum.frequencies_by(results, fn {_row, outcome} -> outcome end)
    if map_size(tally) > 0, do: Logger.info("#{label}: #{inspect(tally)}")

    errored = Map.get(tally, :errored, 0)

    if results != [] and errored == length(results),
      do: {:error, {:all_candidates_errored, errored}},
      else: :ok
  end
end
