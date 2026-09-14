defmodule Loopctl.Intake.IssueClosures do
  @moduledoc """
  The outbox for closing a reporter's GitHub issue (#803 §9, #805 item 1).

  Two halves, deliberately far apart:

  - `record_in/3` runs INSIDE the transaction that writes a story's terminal verdict
    (`Loopctl.Delivery.Stages`). It writes intent and touches no network.
  - `claim_attempt/2`, `mark_labelled/2`, `mark_commented/2`, `mark_closed/2`,
    `mark_transient_failure/3` and `mark_abandoned/3` are called by
    `Loopctl.Delivery.IssueCloser` BETWEEN forge calls, each in its own short transaction.
    **No transaction is ever open across a forge call.**

  ## Why an outbox and not a call at the verdict

  Closing an issue is outward and effectively irreversible: it fires the reporting system's
  webhook, which emails the reporter. Doing it inline would mean either holding a database
  transaction across a network call to GitHub, or performing the outward act after the
  transaction commits and losing it entirely if the node dies in between. The outbox has
  neither problem: the row commits atomically with the verdict, so it cannot be lost, and
  the act happens later with nothing held.

  ## At most once

  The unique index `intake_issue_closures_story_uidx` on `(tenant_id, story_id)`. `record_in/3`
  inserts `ON CONFLICT DO NOTHING`, so a replayed verdict transition — and two concurrent
  ones — produce ONE row between them. Everything after that is a state machine on that one
  row: `:pending` is the only status the drainer picks up, and `:closed` and `:abandoned` are
  terminal.

  ## Retries, and the bound on them

  A TRANSIENT forge fault (`Loopctl.Delivery.MergePrecondition.transient?/1` — unreachable,
  rate-limited, 5xx) bumps `attempts`, sets `next_attempt_at` to an exponential backoff and
  leaves the row `:pending`. Past `max_attempts/0` it is `:abandoned` with
  `retries_exhausted`, because a fault that has not cleared in that many tries is a token or
  an outage and a human is the answer — not a loop.

  A PERMANENT failure — the issue was already closed by somebody else, a 404, a 403 the
  headers say is not a rate limit — abandons on the FIRST occurrence. Retrying it would ask
  a forge that has already given its final answer.

  ## Where it runs, and how it resumes

  Nowhere in particular. Every fact is in Postgres, so a node that dies mid-close leaves a
  row whose markers say exactly how far it got, and the next sweep on any node picks it up.
  There is no process to restart and nothing cached.

  ## Isolation

  Every function here takes `tenant_id` first and filters on it. The ONE exception is
  `due/1`, the drainer's fleet-wide candidate read on `AdminRepo`, which RESOLVES the tenant
  rather than assuming one — the same shape as `Loopctl.Workers.PostDeployVerificationWorker`'s
  candidate query.
  """

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.Intake.IssueClosure
  alias Loopctl.Intake.Record
  alias Loopctl.Intake.Source

  # How many TRANSIENT attempts a closure gets before it becomes a human's problem. A blip
  # clears in seconds; at the backoff below, six attempts spans about an hour and a half of
  # wall clock even when the forge says nothing about when to come back.
  #
  # An earlier version of this note claimed six attempts was "past any rate-limit window
  # GitHub applies", and that was FALSE (#826 review, H1): the backoffs then totalled about
  # half an hour, while GitHub's PRIMARY limit is hourly. A closure hitting a primary limit
  # spent all six attempts inside one window and abandoned with the reporter never told. Two
  # things fix it and both are needed — the schedule below, and `retry_after` being HONOURED
  # rather than computed and dropped.
  @max_attempts 6

  # Exponential, in seconds, indexed by the attempt just made: 3m, 6m, 12m, 24m, 48m. The list
  # is one shorter than `@max_attempts` because there is no wait after the last one.
  #
  # It STARTS ABOVE THE CRON INTERVAL, and that is the other half of H1. The drainer runs
  # every 120s, so the previous first two entries (60s and 120s) were not backoff at all —
  # the row was due again on the very next sweep, and a struggling forge got hit at full
  # cadence for the two attempts that matter most.
  @backoff_seconds [180, 360, 720, 1_440, 2_880]

  # The pessimistic delay `claim_attempt/2` writes BEFORE an attempt runs. See the note there:
  # it is what stops a candidate that RAISES from sitting at the head of the oldest-first
  # queue and being re-served on every sweep.
  @in_flight_backoff_seconds 180

  @typedoc "Why a closure will never be attempted again."
  @type abandon_reason ::
          :closed_by_other
          | :source_revoked
          | :retries_exhausted
          | {:permanent_forge_failure, term()}

  # The abandon reasons an operator may RE-DRIVE, as they are stored (#826 review, finding 4).
  #
  # `retries_exhausted` and `permanent_forge_failure` are both reachable from a MISCONFIGURED
  # DEPLOYMENT — a `GITHUB_TOKEN` without `issues: write` 403s every closure in the window and
  # abandons each on its first attempt — so the operator who fixes the secret needs the
  # backlog to be recoverable rather than dead.
  #
  # `closed_by_other` is deliberately NOT here, and never should be. It means a human already
  # closed the reporter's issue; re-driving it is the duplicate close this whole module exists
  # to prevent, and no amount of fixing a token makes it right.
  @requeueable_prefixes ["retries_exhausted", "permanent_forge_failure"]

  @doc "How many transient attempts a closure gets. See the moduledoc."
  @spec max_attempts() :: pos_integer()
  def max_attempts, do: @max_attempts

  @doc """
  Records the INTENT to close a story's linked issue, in the CALLER'S transaction.

  Called by `Loopctl.Delivery.Stages` from inside the transition that writes a terminal
  verdict, so the row and the verdict commit together or neither does. `repo` is the caller's
  repo — `Loopctl.Repo` inside a `with_tenant/2` block — and no transaction of its own is
  opened here.

  `record_id` is the story's `intake_record_id`, which the stage writer already holds from
  the row it locked; `nil` is `:no_link`.

  Returns `:ok` when a row now exists (this call wrote it, or a previous one did), and
  `:no_link` when the story came from no intake record, or its record's source has gone.
  Neither is an error, and `:no_link` is the ORDINARY case: most stories are authored rather
  than reported.

  Idempotent by the unique index: `ON CONFLICT DO NOTHING`, so a replayed transition and two
  concurrent ones leave exactly one row.

  A failure here is deliberately NOT caught. The insert has no reachable failure mode — every
  value comes from a row read in this same transaction, and every CHECK is satisfied by
  construction — so anything that does fail is a bug, and committing the verdict while
  silently dropping the record of what to tell the reporter is the one outcome an outbox may
  not have. Raising rolls the transition back and the caller retries it.
  """
  @spec record_in(Ecto.Repo.t(), Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t() | nil, atom()) ::
          :ok | :no_link
  def record_in(_repo, _tenant_id, _story_id, nil, _verdict), do: :no_link

  def record_in(repo, tenant_id, story_id, record_id, verdict)
      when is_binary(record_id) and is_atom(verdict) do
    true = verdict in IssueClosure.verdicts()

    case target(repo, tenant_id, record_id) do
      {:ok, target} -> insert(repo, tenant_id, story_id, record_id, verdict, target)
      :no_link -> :no_link
    end
  end

  # WHERE the close will land, read once at verdict time and stored on the row.
  #
  # The repository comes from the SOURCE and the issue number from the RECORD. Both are
  # captured now rather than joined at close time, so the outward act addresses the issue the
  # verdict was actually about — a later delivery can move a record's content, but it may not
  # redirect a close that was already decided.
  #
  # A record whose source is gone, or REVOKED, is `:no_link`: revoking a source is a tenant
  # disconnecting a repository, and loopctl may not keep writing to it afterwards (#826
  # review, finding 6). Refusing here is the smaller of the two windows the review offered —
  # no row is recorded at all, so there is nothing to drain — and `source_live?/2` below
  # covers the other one, a source revoked AFTER the row was written.
  defp target(repo, tenant_id, record_id) do
    from(r in Record,
      join: s in Source,
      on: s.id == r.source_id and s.tenant_id == r.tenant_id,
      where: r.tenant_id == ^tenant_id and r.id == ^record_id,
      where: is_nil(s.revoked_at),
      select: %{repo_full_name: s.repo_full_name, issue_number: r.issue_number}
    )
    |> repo.one()
    |> case do
      %{issue_number: number} = target when is_integer(number) -> {:ok, target}
      _missing -> :no_link
    end
  end

  @doc """
  Whether the intake source a closure targets is still connected.

  Read by `Loopctl.Delivery.IssueCloser` BEFORE its first forge call, and it closes the half
  of finding 6 that `target/3` cannot: a source revoked AFTER the verdict was recorded. The
  tenant disconnected that repository, and the write scope this feature added means "keep
  going anyway" would label, comment on and close an issue there regardless.

  `false` also for a record or source that has been deleted outright — there is nothing to
  address, and the closer abandons rather than guessing.
  """
  @spec source_live?(IssueClosure.t()) :: boolean()
  def source_live?(%IssueClosure{tenant_id: tenant_id, intake_record_id: record_id}) do
    AdminRepo.exists?(
      from r in Record,
        join: s in Source,
        on: s.id == r.source_id and s.tenant_id == r.tenant_id,
        where: r.tenant_id == ^tenant_id and r.id == ^record_id,
        where: is_nil(s.revoked_at)
    )
  end

  defp insert(repo, tenant_id, story_id, record_id, verdict, target) do
    now = DateTime.utc_now()

    row = %{
      id: Ecto.UUID.generate(),
      tenant_id: tenant_id,
      story_id: story_id,
      intake_record_id: record_id,
      repo_full_name: target.repo_full_name,
      issue_number: target.issue_number,
      verdict: verdict,
      status: :pending,
      attempts: 0,
      inserted_at: now,
      updated_at: now
    }

    # The unique indexes decide the replay. Zero rows inserted means a closure for this story
    # — or for its intake record — already exists, which is success, not a conflict.
    #
    # NO `conflict_target`, deliberately (#826 round 2, finding 5). A target names ONE index,
    # so a conflict on the other raised instead — inside a function whose moduledoc says a
    # failure here is uncaught on purpose, which would roll the verdict transition back and
    # leave the story permanently un-advanceable. The record-level index exists as insurance
    # for the day the story-level one does not hold, and insurance that wedges a story is
    # worse than none.
    #
    # Untargeted `ON CONFLICT DO NOTHING` covers every unique violation on the table and
    # nothing else: a foreign-key or CHECK failure still raises, which is what the uncaught
    # rule is actually about.
    _ = repo.insert_all(IssueClosure, [row], on_conflict: :nothing)

    :ok
  end

  @doc "Gets one tenant's closure row for a story."
  @spec get(Ecto.UUID.t(), Ecto.UUID.t()) :: IssueClosure.t() | nil
  def get(tenant_id, story_id) when is_binary(tenant_id) and is_binary(story_id) do
    AdminRepo.one(
      from c in IssueClosure,
        where: c.tenant_id == ^tenant_id and c.story_id == ^story_id
    )
  end

  @doc "Lists one tenant's closure rows, oldest first. `:status` filters."
  @spec list(Ecto.UUID.t(), keyword()) :: [IssueClosure.t()]
  def list(tenant_id, opts \\ []) when is_binary(tenant_id) do
    query =
      from c in IssueClosure,
        where: c.tenant_id == ^tenant_id,
        order_by: [asc: c.inserted_at, asc: c.id]

    query =
      case Keyword.get(opts, :status) do
        nil -> query
        status -> where(query, [c], c.status == ^status)
      end

    AdminRepo.all(query)
  end

  @doc """
  The closures due for an attempt, fleet-wide, oldest first — the drainer's candidate set.

  `:pending` only, and only those whose backoff has elapsed. On `AdminRepo` (BYPASSRLS), so
  the explicit predicates here are the only scoping there is; the tenant is RESOLVED from
  the row rather than assumed, which is what makes a fleet-wide sweep correct.
  """
  @spec due(pos_integer()) :: [IssueClosure.t()]
  def due(limit) when is_integer(limit) and limit > 0 do
    now = DateTime.utc_now()

    AdminRepo.all(
      from c in IssueClosure,
        where: c.status == :pending,
        where: is_nil(c.next_attempt_at) or c.next_attempt_at <= ^now,
        order_by: [asc: c.inserted_at, asc: c.id],
        limit: ^limit
    )
  end

  @doc """
  Marks an attempt as STARTED: bumps `attempts` and schedules the NEXT one pessimistically.

  Taken BEFORE the first forge call of an attempt, and it is a compare-and-set on
  `:pending` — so two drainers that both read the same candidate cannot both proceed to make
  outward calls for it. The loser gets `{:error, :not_pending}` and moves on.

  Bumping the counter FIRST is deliberate: a run that dies mid-attempt has still spent one,
  so `max_attempts/0` bounds crashes as well as forge faults. A counter bumped only on a
  recorded failure would let a crash loop run for ever.

  **Writing a backoff here, rather than clearing one, is what stops a raising candidate from
  wedging the whole drainer** (#826 review, finding 5). `due/1` reads oldest-first, so a row
  whose attempt RAISES — rather than returning an error anything can record — would otherwise
  be first in the candidate set on every subsequent sweep, and one issue could stall every
  other tenant's closures fleet-wide. Scheduled forward before the attempt runs, a crash
  behaves like a transient failure: the row waits, the batch moves on, and the attempt
  counter still bounds it.

  Every path that reaches a verdict overwrites this: `mark_closed/2` clears it,
  `mark_transient_failure/4` replaces it with the real delay.

  ## The forward schedule is ALSO the mutual exclusion (#826 round 2, H1)

  The predicate is `status == :pending` **AND the row being DUE** — `next_attempt_at` null or
  in the past — and the update pushes `next_attempt_at` forward. Those two together are the
  compare-and-set: of two drainers that read the same candidate, the first commits and moves
  the row out of "due", and the second matches nothing and is refused `:not_pending`.

  The status test alone was NOT mutual exclusion, and three moduledocs called it one. A claim
  leaves the row `:pending`, so both callers matched, both got `{:ok, claimed}`, and both went
  on to label, COMMENT and close — two resolution comments on the reporter's ticket. Nothing
  in this module prevented it; what happened to prevent it in practice was Oban's `unique`
  option plus cron leadership, which is not the stated mechanism and does not survive a manual
  enqueue or a retry landing beside a slow run.

  The loser's `{:error, :not_pending}` is therefore an ordinary outcome under concurrency, not
  a bug: `Loopctl.Delivery.IssueCloser` reports it as `:skipped` and makes no forge call.
  """
  @spec claim_attempt(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, IssueClosure.t()} | {:error, :not_pending}
  def claim_attempt(tenant_id, id) do
    now = DateTime.utc_now()

    update_pending(
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

  @doc "Records that the resolution label is on the issue."
  @spec mark_labelled(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, IssueClosure.t()} | {:error, :not_pending}
  def mark_labelled(tenant_id, id), do: stamp(tenant_id, id, :labelled_at)

  @doc "Records that the resolution text has been posted to the issue."
  @spec mark_commented(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, IssueClosure.t()} | {:error, :not_pending}
  def mark_commented(tenant_id, id), do: stamp(tenant_id, id, :commented_at)

  @doc """
  Records that the issue is closed. Terminal.

  Also written when the closer discovers the issue is ALREADY closed and carries one of
  loopctl's resolution labels — that is our own close, seen on a replay, and the correct
  record of it is the same one.
  """
  @spec mark_closed(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, IssueClosure.t()} | {:error, :not_pending}
  def mark_closed(tenant_id, id) do
    now = DateTime.utc_now()

    update_pending(tenant_id, id,
      set: [
        status: :closed,
        closed_at: now,
        last_error: nil,
        next_attempt_at: nil,
        updated_at: now
      ]
    )
  end

  @doc """
  Records a TRANSIENT failure: stays `:pending`, backs off, and abandons at the bound.

  Returns `{:ok, row}` with the row's new state either way — `:pending` while attempts
  remain, `:abandoned` with `retries_exhausted` once they do not — so a caller never has to
  count them itself.

  ## `retry_after` is HONOURED, not merely reported (#826 review, H1)

  `retry_after` is the delay the FORGE asked for, in seconds, or `nil` when it said nothing.
  The wait is `max(backoff, retry_after)`, and the `max` is load-bearing in both directions:
  the forge's number wins when it is longer, and the local schedule wins when the forge asks
  for a token gesture.

  It was computed and thrown away before, and that lost the case it was computed FOR. GitHub's
  primary rate limit resets on an HOURLY boundary and says so on `x-ratelimit-reset`, which
  `GitHubPullRequestSource` already parses into this value — so a closure that hit one spent
  every attempt inside a single window it was told the end of, and abandoned with the reporter
  never told what happened to her issue.
  """
  @spec mark_transient_failure(Ecto.UUID.t(), IssueClosure.t(), term(), pos_integer() | nil) ::
          {:ok, IssueClosure.t()} | {:error, :not_pending}
  def mark_transient_failure(tenant_id, %IssueClosure{} = closure, reason, retry_after \\ nil) do
    if closure.attempts >= @max_attempts do
      mark_abandoned(tenant_id, closure.id, :retries_exhausted, reason)
    else
      now = DateTime.utc_now()
      wait = wait_seconds(closure.attempts, retry_after)

      update_pending(tenant_id, closure.id,
        set: [
          next_attempt_at: DateTime.add(now, wait, :second),
          last_error: error_text(reason),
          updated_at: now
        ]
      )
    end
  end

  @doc """
  The seconds a transient failure waits: the local backoff, or the forge's `retry_after` when
  that is longer.

  Public because it is the one number H1 turned on, and a bound that cannot be asserted
  directly is a bound nobody can prove still holds.
  """
  @spec wait_seconds(non_neg_integer(), pos_integer() | nil) :: pos_integer()
  def wait_seconds(attempts_made, retry_after) do
    backoff = backoff(attempts_made)

    if is_integer(retry_after) and retry_after > backoff, do: retry_after, else: backoff
  end

  @doc """
  Records that this closure will NEVER be attempted again, and why. Terminal.

  The reason is stored as a readable string; `reason` is the forge detail behind it, echoed
  onto `last_error` by SHAPE-bounded inspection so a remote body can never be the thing that
  makes the write fail.
  """
  @spec mark_abandoned(Ecto.UUID.t(), Ecto.UUID.t(), abandon_reason(), term()) ::
          {:ok, IssueClosure.t()} | {:error, :not_pending}
  def mark_abandoned(tenant_id, id, abandon_reason, reason \\ nil) do
    now = DateTime.utc_now()

    update_pending(tenant_id, id,
      set: [
        status: :abandoned,
        abandoned_reason: abandon_text(abandon_reason),
        last_error: error_text(reason),
        next_attempt_at: nil,
        updated_at: now
      ]
    )
  end

  @doc """
  Moves ABANDONED closures back to `:pending` so the drainer picks them up again.

  The operator's way back from a deploy-time misconfiguration (#826 review, finding 4). The
  likeliest cause of a mass abandonment is a `GITHUB_TOKEN` without `issues: write`: every
  closure in the window 403s, which is permanent and correctly abandons on the first attempt —
  and before this existed, nothing in `lib/` could move a non-pending row, so fixing the
  secret left the whole backlog dead with no reporter ever told.

  ## It MUST be bounded, and it counts before it writes (#826 round 2, finding 3)

  A closure abandoned months ago by an unrelated outage still names a live GitHub issue. Waking
  it puts a fresh label, comment and close on a ticket the reporter has long since moved on
  from, carrying a verdict about work nobody remembers. So an unbounded call is REFUSED:

      # look first — counts, writes nothing
      IssueClosures.requeue_abandoned(abandoned_after: ~U[2026-09-13 00:00:00Z], dry_run: true)

      # then act, over the same window
      IssueClosures.requeue_abandoned(abandoned_after: ~U[2026-09-13 00:00:00Z])

      IssueClosures.requeue_abandoned(id: closure_id)     # one row, inherently bounded
      IssueClosures.requeue_abandoned(unbounded: true)    # everything, said out loud

  Returns `{:ok, count}`, or `{:error, :bound_required}` when none of `:abandoned_after`,
  `:id` or `unbounded: true` is given. `:tenant_id` NARROWS a window; it is not a bound of its
  own, because one tenant's whole history is exactly the blast radius this guards.

  The window is read from `updated_at`, which is when the row was abandoned: nothing writes to
  a terminal row afterwards.

  **`closed_by_other` and `source_revoked` are never requeued**, whatever is passed. A human
  already closed that reporter's issue, or the tenant disconnected the repository; re-driving
  either is the outward act this module exists to prevent, and fixing a token makes neither
  right.

  The safety argument for the rest is narrower than it looks and is stated rather than
  assumed: a row whose issue loopctl DID close is caught by the closer's read of the live
  state and recorded without a second outward call — but an ordinary `retries_exhausted` row's
  issue is still open, and that one really will be closed. The time bound is what makes that
  acceptable.

  `attempts` is reset, because the operator fixing the cause is what makes a fresh budget
  meaningful; a requeue that inherited an exhausted counter would abandon again immediately.
  The step MARKERS are deliberately not reset — a comment already posted must not be posted
  again.
  """
  @spec requeue_abandoned(keyword()) ::
          {:ok, non_neg_integer()} | {:error, :bound_required}
  def requeue_abandoned(opts \\ []) do
    if bounded?(opts), do: do_requeue(opts), else: {:error, :bound_required}
  end

  # `:tenant_id` is NOT a bound. One tenant's entire abandoned history is precisely the set
  # that should not wake up together, so narrowing to it changes the blast radius' owner and
  # not its size.
  defp bounded?(opts) do
    Keyword.has_key?(opts, :id) or
      match?(%DateTime{}, Keyword.get(opts, :abandoned_after)) or
      Keyword.get(opts, :unbounded) == true
  end

  defp do_requeue(opts) do
    query =
      from c in IssueClosure,
        where: c.status == :abandoned,
        where:
          fragment(
            "EXISTS (SELECT 1 FROM unnest(?::text[]) p WHERE ? LIKE p || '%')",
            ^@requeueable_prefixes,
            c.abandoned_reason
          )

    query =
      Enum.reduce(opts, query, fn
        {:tenant_id, tenant_id}, q -> where(q, [c], c.tenant_id == ^tenant_id)
        {:id, id}, q -> where(q, [c], c.id == ^id)
        {:abandoned_after, %DateTime{} = at}, q -> where(q, [c], c.updated_at >= ^at)
        _other, q -> q
      end)

    if Keyword.get(opts, :dry_run) == true,
      do: {:ok, AdminRepo.aggregate(query, :count)},
      else: apply_requeue(query)
  end

  defp apply_requeue(query) do
    {count, _} =
      AdminRepo.update_all(query,
        set: [
          status: :pending,
          abandoned_reason: nil,
          attempts: 0,
          next_attempt_at: nil,
          updated_at: DateTime.utc_now()
        ]
      )

    {:ok, count}
  end

  @doc "The stored `abandoned_reason` prefixes `requeue_abandoned/1` will re-drive."
  @spec requeueable_reasons() :: [String.t()]
  def requeueable_reasons, do: @requeueable_prefixes

  # -- writes ------------------------------------------------------------------------------

  defp stamp(tenant_id, id, field) do
    now = DateTime.utc_now()
    update_pending(tenant_id, id, set: [{field, now}, {:updated_at, now}])
  end

  # EVERY write is a compare-and-set on `:pending`, on the tenant's own row.
  #
  # That is what makes the whole thing safe under two concurrent drainers and under a replay:
  # once a row is `:closed` or `:abandoned` nothing can move it, so a late writer from an
  # earlier attempt cannot resurrect it, un-close it, or reset its backoff.
  defp update_pending(tenant_id, id, updates, extra_predicate \\ nil) do
    query =
      from c in IssueClosure,
        where: c.tenant_id == ^tenant_id and c.id == ^id and c.status == :pending,
        select: c

    query = if extra_predicate, do: where(query, ^extra_predicate), else: query

    case AdminRepo.update_all(query, updates) do
      {1, [row]} -> {:ok, row}
      {0, _none} -> {:error, :not_pending}
    end
  end

  # WHICH DELAY an attempt waits, indexed from the attempt just MADE.
  #
  # `attempts_made` is 1 after the first claim, so the index is one less. Zero is guarded
  # explicitly rather than left to `Enum.at/3`, which treats -1 as "from the end" and would
  # return the LONGEST delay as the shortest — a 48-minute first backoff. It is unreachable
  # through `close/1`, which always claims before it can fail, but `wait_seconds/2` is public
  # precisely so the schedule can be asserted without driving a closure, and an assertion
  # helper that lies about its own first entry is worse than no helper (#826 round 2,
  # finding 4).
  defp backoff(attempts_made) when attempts_made <= 1, do: hd(@backoff_seconds)

  defp backoff(attempts_made),
    do: Enum.at(@backoff_seconds, attempts_made - 1, List.last(@backoff_seconds))

  defp abandon_text(:closed_by_other), do: "closed_by_other"
  defp abandon_text(:source_revoked), do: "source_revoked"
  defp abandon_text(:retries_exhausted), do: "retries_exhausted"

  defp abandon_text({:permanent_forge_failure, reason}),
    do: "permanent_forge_failure: #{error_text(reason)}"

  # A forge reason is REMOTE DATA, and this is the ONE column built from an unbounded amount
  # of it. Only its inspected form, bounded, reaches the row.
  #
  # BOUNDED IN CODE POINTS, because that is what the `intake_issue_closures_text_bounds` CHECK
  # counts (`char_length`). `String.slice/3` counts GRAPHEMES, and a grapheme can be several
  # code points — so a reason carrying emoji or combining marks passed the slice at 1,900
  # graphemes and arrived at Postgres well over 2,000 code points (#826 review, finding 5).
  # The CHECK then raised INSIDE `mark_abandoned/4`, which is precisely the write that says
  # "never retry this": the row stayed `:pending`, `due/1` reads oldest-first, and one issue
  # with a decorated label could abort every subsequent sweep for every tenant.
  #
  # The blast radius is fixed in three places and all three are wanted: this bound, the
  # pessimistic schedule in `claim_attempt/2` so a raise cannot hold the head of the queue,
  # and the callers no longer echoing RAW LABEL NAMES into a reason at all.
  @error_text_budget 1_900

  defp error_text(nil), do: nil

  defp error_text(reason) do
    text = inspect(reason)
    chars = String.to_charlist(text)

    if length(chars) > @error_text_budget,
      do: chars |> Enum.take(@error_text_budget) |> List.to_string(),
      else: text
  end
end
