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
  # clears in seconds; at the backoff below, six attempts spans about half an hour, which is
  # past any rate-limit window GitHub applies and well past an outage worth waiting out.
  @max_attempts 6

  # Exponential, in seconds, indexed by the attempt just made: 1m, 2m, 4m, 8m, 16m. The list
  # is one shorter than `@max_attempts` because there is no wait after the last one.
  @backoff_seconds [60, 120, 240, 480, 960]

  @typedoc "Why a closure will never be attempted again."
  @type abandon_reason ::
          :closed_by_other
          | :retries_exhausted
          | {:permanent_forge_failure, term()}

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
  # verdict was actually about — a later delivery can move a record's content, and a source
  # can be revoked, but neither may redirect a close that was already decided.
  #
  # A record whose source is gone is `:no_link`: there is nothing to address.
  defp target(repo, tenant_id, record_id) do
    from(r in Record,
      join: s in Source,
      on: s.id == r.source_id and s.tenant_id == r.tenant_id,
      where: r.tenant_id == ^tenant_id and r.id == ^record_id,
      select: %{repo_full_name: s.repo_full_name, issue_number: r.issue_number}
    )
    |> repo.one()
    |> case do
      %{issue_number: number} = target when is_integer(number) -> {:ok, target}
      _missing -> :no_link
    end
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

    # The unique index decides the replay. Zero rows inserted means a row for this story
    # already exists — this verdict has been recorded — which is success, not a conflict.
    _ =
      repo.insert_all(IssueClosure, [row],
        on_conflict: :nothing,
        conflict_target: [:tenant_id, :story_id]
      )

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
  Marks an attempt as STARTED: bumps `attempts` and clears `next_attempt_at`.

  Taken BEFORE the first forge call of an attempt, and it is a compare-and-set on
  `:pending` — so two drainers that both read the same candidate cannot both proceed to make
  outward calls for it. The loser gets `{:error, :not_pending}` and moves on.

  Bumping the counter FIRST is deliberate: a run that dies mid-attempt has still spent one,
  so `max_attempts/0` bounds crashes as well as forge faults. A counter bumped only on a
  recorded failure would let a crash loop run for ever.
  """
  @spec claim_attempt(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, IssueClosure.t()} | {:error, :not_pending}
  def claim_attempt(tenant_id, id) do
    update_pending(tenant_id, id,
      set: [next_attempt_at: nil, updated_at: DateTime.utc_now()],
      inc: [attempts: 1]
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
  """
  @spec mark_transient_failure(Ecto.UUID.t(), IssueClosure.t(), term()) ::
          {:ok, IssueClosure.t()} | {:error, :not_pending}
  def mark_transient_failure(tenant_id, %IssueClosure{} = closure, reason) do
    if closure.attempts >= @max_attempts do
      mark_abandoned(tenant_id, closure.id, :retries_exhausted, reason)
    else
      now = DateTime.utc_now()

      update_pending(tenant_id, closure.id,
        set: [
          next_attempt_at: DateTime.add(now, backoff(closure.attempts), :second),
          last_error: error_text(reason),
          updated_at: now
        ]
      )
    end
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
  defp update_pending(tenant_id, id, updates) do
    query =
      from c in IssueClosure,
        where: c.tenant_id == ^tenant_id and c.id == ^id and c.status == :pending,
        select: c

    case AdminRepo.update_all(query, updates) do
      {1, [row]} -> {:ok, row}
      {0, _none} -> {:error, :not_pending}
    end
  end

  defp backoff(attempts_made) do
    Enum.at(@backoff_seconds, attempts_made - 1, List.last(@backoff_seconds))
  end

  defp abandon_text(:closed_by_other), do: "closed_by_other"
  defp abandon_text(:retries_exhausted), do: "retries_exhausted"

  defp abandon_text({:permanent_forge_failure, reason}),
    do: "permanent_forge_failure: #{error_text(reason)}"

  # A forge reason is REMOTE DATA. Only its inspected form, bounded, reaches a stored column
  # and the operator log — the CHECK caps it at 2000 characters, and a write that the CHECK
  # rejects would roll back the one record that says this close must not be retried.
  defp error_text(nil), do: nil
  defp error_text(reason), do: reason |> inspect() |> String.slice(0, 1_900)
end
