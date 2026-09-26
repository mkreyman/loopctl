defmodule Loopctl.Delivery.RunnerThreads do
  @moduledoc """
  Applies a runner's `checkpoint` and `thread_entry` messages to the story's change thread
  (epic 45, US-45.2, runner contract 1.20.0).

  A COORDINATOR, not a second writer, exactly as `Loopctl.Delivery.RunnerStages` is for
  `story_stages`: `Loopctl.Threads` stays the only thing that writes a thread, and the HTTP
  surface calls the same two functions with the same fence. What happens here is what the
  channel process should not carry:

  1. resolve the runner's dispatch to its story, from the ledger row — the story is NEVER
     taken off the wire — and refuse any kind but `implement` as `:unknown_dispatch`
     (`Loopctl.Runners.DispatchLedger.implement_kind?/1`), as `session_ended` does: a triage
     session has no claim to report on;
  2. refuse an epoch that is not even the dispatch's, before the write's transaction opens;
  3. resolve WHO is writing, from the server's own rows, never from the message;
  4. translate `Loopctl.Threads`' refusals into the reasons the contract publishes.

  Steps 1 and 3 are ONE read in one tenant transaction: the ledger row, its story's current
  epoch, and the custody dispatch's lineage.

  ## A dispatch no longer accepted

  A NEW write needs the dispatch `accepted`. A RESEND of a write already recorded is answered
  from the row whatever the dispatch's status by then, because the release that ends a claim
  lets a reply or trace mark the row `superseded` before the resend of a lost ack arrives, and
  the runner must still learn that its write landed. `Loopctl.Threads`' `:replay_only` does
  that: it answers the resend and refuses anything new `:dispatch_not_accepted`.

  ## Who the write is attributed to

  The principal is the runner's AGENT (`runners.agent_id`), spelled by
  `LoopctlWeb.ActorLabel.agent/1`, the function `LoopctlWeb.ActorLabel.of/1` spells a key with
  an agent through. It has to be that agent: a placement claims the story AS the runner's
  agent (`Loopctl.Delivery.Placement`), so it is the identity `Loopctl.Delivery.Claimant`
  compares against `assigned_agent_id`, and it is the one a resend must repeat for
  `Loopctl.Threads` to recognise its own earlier write.

  The LINEAGE is the custody dispatch's — the session dispatch a placement minted and the
  claim recorded as `stories.implementer_dispatch_id` — and not the runner key's. The runner
  authenticates with its ENROLLMENT key, which no dispatch minted, so its own lineage is `[]`
  (`RunnerStages` states that, correctly, for its writes). A checkpoint attributed to `[]`
  would name no dispatch on the thread or on its audit-chain entry, on work a dispatch did.

  It is taken only while the story's `claim_epoch` is still the message's. After that,
  `implementer_dispatch_id` belongs to whichever claim came next, so the lineage is not this
  session's to take; it resolves to `[]`, and nothing NEW is written under it:

  - a `checkpoint` meets the claimant fence, which refuses a new write at an ended epoch;
  - a `thread_entry` carries the message's epoch into `Loopctl.Threads.record_entry/4`
    (`:claim_epoch`), which refuses a new one `:stale_claim_epoch` UNDER the story's lock, so
    a claim that moves between this read and the write is refused there, never written past.
    Because `implementer_dispatch_id` only changes with a claim, which bumps the epoch, a
    lineage read at epoch E is still E's once the lock confirms E.

  Either one's resend is answered from its row, and writes nothing.

  A claim with no custody dispatch (a legacy claim no placement made) resolves to `[]`, which
  is what that claim genuinely has.

  ## Database failures, answered rather than raised

  Anything raised here is raised inside the runner channel's `handle_in`, where it takes down
  every session on the socket, and the runner's resend on rejoin crash-loops it. So the whole
  of both functions — the read as well as the write — runs inside two answers:

  - a lock wait that ran out, a deadlock Postgres broke by choosing this write, or a pool
    checkout that timed out is `:busy` (`Loopctl.Delivery.Stages.retryable_error?/1`): nothing
    was written and the same message will do. `Loopctl.Threads` answers the same conditions
    `:busy` for its own locks, for the HTTP surface;
  - the tenant's audit chain refusing the append as a HASH violation is
    `:audit_chain_append_failed` (`RunnerStages.answering_broken_chain/3`, the one copy of
    that policy), exactly as a `stage` is.

  Every other database error still raises.

  ## The custody halt

  Neither message checks it, and neither does the HTTP surface: `LoopctlWeb.CustodySurface`
  does not classify a thread write as custody progress. A thread is a record of what a
  session did; what a halt must stop is a merge adopting it, which is US-45.5's gate.

  ## Retries

  Both are safe to repeat, because `Loopctl.Threads` makes them so: a checkpoint by
  `(commit_sha, claim_epoch)` and its recorder, an entry by its author and idempotency key,
  `<dispatch_id>:<client_seq>`. The reply says which it was (`replayed?`).
  """

  import Ecto.Query

  require Logger

  alias Loopctl.Delivery.RunnerStages
  alias Loopctl.Delivery.Stages
  alias Loopctl.Dispatches.Dispatch
  alias Loopctl.Repo
  alias Loopctl.Runners.DispatchLedger
  alias Loopctl.Runners.DispatchRecord
  alias Loopctl.Threads
  alias Loopctl.Threads.Checkpoint
  alias Loopctl.Threads.Entry
  alias Loopctl.WorkBreakdown.Story
  alias LoopctlWeb.ActorLabel

  @type error ::
          :unknown_dispatch
          | :dispatch_not_accepted
          | :stale_claim_epoch
          | :not_claimant
          | :claim_not_live
          | :checkpoint_conflict
          | :idempotency_key_reused
          | :secret_blocked
          | :audit_chain_append_failed
          | :busy
          | {:invalid, [String.t()]}

  @typedoc "The runner the socket authenticated: its id and the agent its sessions work as."
  @type runner :: %{required(:id) => Ecto.UUID.t(), required(:agent_id) => Ecto.UUID.t()}

  @doc """
  Records `message` — already cast by `Loopctl.ApiSpec.RunnerContract.cast_checkpoint/1` — as
  a checkpoint of the story `runner`'s implement dispatch is for.
  """
  @spec record_checkpoint(Ecto.UUID.t(), runner(), map()) ::
          {:ok, %{checkpoint: Checkpoint.t(), replayed?: boolean()}} | {:error, error() | term()}
  def record_checkpoint(tenant_id, runner, %{} = message) do
    answering_database(tenant_id, message, "checkpoint", fn ->
      with {:ok, session} <- session(tenant_id, runner.id, message) do
        tenant_id
        |> Threads.record_checkpoint(session.story_id,
          agent_id: runner.agent_id,
          claim_epoch: message.claim_epoch,
          commit_sha: message.commit_sha,
          tree_sha: message.tree_sha,
          note: Map.get(message, :note),
          author_principal: principal(runner),
          actor_lineage: session.lineage,
          replay_only: not session.accepted?
        )
        |> answer(:checkpoint)
      end
    end)
  end

  @doc """
  Records `message` — already cast by `Loopctl.ApiSpec.RunnerContract.cast_thread_entry/1` —
  as a `message` entry on the thread of the story `runner`'s implement dispatch is for, under
  the idempotency key `<dispatch_id>:<client_seq>`.
  """
  @spec record_entry(Ecto.UUID.t(), runner(), map()) ::
          {:ok, %{entry: Entry.t(), replayed?: boolean()}} | {:error, error() | term()}
  def record_entry(tenant_id, runner, %{} = message) do
    answering_database(tenant_id, message, "thread_entry", fn ->
      with {:ok, session} <- session(tenant_id, runner.id, message) do
        attrs =
          %{
            "kind" => "message",
            "idempotency_key" => idempotency_key(message),
            "body" => message.body
          }
          |> put_checkpoint(Map.get(message, :checkpoint_id))

        tenant_id
        |> Threads.record_entry(session.story_id, attrs,
          author_principal: principal(runner),
          actor_lineage: session.lineage,
          claim_epoch: message.claim_epoch,
          replay_only: not session.accepted?
        )
        |> answer(:entry)
      end
    end)
  end

  @doc "The idempotency key of a `thread_entry`: `<dispatch_id>:<client_seq>`."
  @spec idempotency_key(%{dispatch_id: Ecto.UUID.t(), client_seq: non_neg_integer()}) ::
          String.t()
  def idempotency_key(%{dispatch_id: dispatch_id, client_seq: client_seq}),
    do: "#{dispatch_id}:#{client_seq}"

  @doc "The principal a runner's thread writes carry: its agent (`ActorLabel.agent/1`)."
  @spec principal(runner()) :: String.t()
  def principal(%{agent_id: agent_id}), do: ActorLabel.agent(agent_id)

  # --- the session -----------------------------------------------------------------------

  # The ledger row `runner_id` holds for the message's dispatch, whatever its status, with its
  # story's current epoch and the custody dispatch's lineage, in one read. A row another
  # runner or tenant holds reads as none. The ledger holds no foreign key to the story, so a
  # deleted story leaves a dispatch naming nothing — `unknown_dispatch`, permanently.
  # `implementer_dispatch_id` is a foreign key with no delete, so a declared dispatch always
  # resolves.
  defp session(tenant_id, runner_id, message) do
    {:ok, row} =
      Repo.with_tenant(tenant_id, fn ->
        Repo.one(
          from r in DispatchRecord,
            left_join: s in Story,
            on: s.id == r.story_id and s.tenant_id == r.tenant_id,
            left_join: d in Dispatch,
            on: d.id == s.implementer_dispatch_id and d.tenant_id == s.tenant_id,
            where: r.tenant_id == ^tenant_id and r.runner_id == ^runner_id,
            where: r.dispatch_id == ^message.dispatch_id,
            select: %{
              status: r.status,
              kind: r.kind,
              story_id: r.story_id,
              claim_epoch: r.claim_epoch,
              story_found?: not is_nil(s.id),
              story_epoch: s.claim_epoch,
              lineage: d.lineage_path
            }
        )
      end)

    with {:ok, row} <- found(row),
         :ok <- implement_kind(row),
         :ok <- dispatch_epoch_matches(row, message) do
      {:ok,
       %{
         story_id: row.story_id,
         accepted?: row.status == "accepted",
         lineage: lineage(row, message.claim_epoch)
       }}
    end
  end

  defp found(%{story_found?: true} = row), do: {:ok, row}
  defp found(_none), do: {:error, :unknown_dispatch}

  defp implement_kind(%{kind: kind}) do
    if DispatchLedger.implement_kind?(kind), do: :ok, else: {:error, :unknown_dispatch}
  end

  # Not the fence: `Loopctl.Threads` reads the story's epoch under its lock, which is what
  # decides. A message that does not even match the dispatch it names is refused here for the
  # cost of the read already made.
  defp dispatch_epoch_matches(%{claim_epoch: epoch}, %{claim_epoch: epoch}), do: :ok
  defp dispatch_epoch_matches(_row, _message), do: {:error, :stale_claim_epoch}

  # The custody dispatch's lineage while the story's claim is still the message's, `[]` once
  # it is not; see the moduledoc for why nothing new is written under the latter.
  defp lineage(%{story_epoch: epoch, lineage: lineage}, epoch), do: lineage || []
  defp lineage(_row, _epoch), do: []

  defp put_checkpoint(attrs, nil), do: attrs
  defp put_checkpoint(attrs, checkpoint_id), do: Map.put(attrs, "checkpoint_id", checkpoint_id)

  # --- answers ---------------------------------------------------------------------------

  defp answer({:ok, record, status}, key),
    do: {:ok, %{key => record, replayed?: status == :existing}}

  defp answer({:error, reason}, _key), do: {:error, classify(reason)}
  defp answer({:error, :unprocessable_entity, detail}, _key), do: {:error, unprocessable(detail)}

  defp classify({:conflict, "checkpoint_conflict", _message}), do: :checkpoint_conflict
  defp classify({:conflict, "idempotency_key_reused", _message}), do: :idempotency_key_reused

  defp classify(%Ecto.Changeset{data: %Entry{}} = changeset),
    do: {:invalid, changeset_messages(changeset)}

  # Every other reason passes through to `LoopctlWeb.RunnerChannel.Refusal`, which publishes
  # `:not_claimant`, `:stale_claim_epoch`, `:claim_not_live`, `:dispatch_not_accepted` and
  # `:audit_chain_append_failed` under their own names and `:busy` as `rate_limited` with a
  # retry interval. Anything it does not name reaches its catch-all, which logs it and answers
  # `internal_error` — `Loopctl.Threads`' `:not_found` among them, which only a story deleted
  # between `session/3` and the write can produce.
  defp classify(reason), do: reason

  # Total, because a clause missing here raises inside the channel: a structured 422 this
  # module does not name yet is still an `invalid_payload` carrying its message.
  defp unprocessable(%{code: "secret_blocked"}), do: :secret_blocked
  defp unprocessable(%{message: message}) when is_binary(message), do: {:invalid, [message]}
  defp unprocessable(message) when is_binary(message), do: {:invalid, [message]}
  defp unprocessable(detail), do: {:invalid, [inspect(detail)]}

  defp changeset_messages(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, opts} ->
      Enum.reduce(opts, message, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string_safe(value))
      end)
    end)
    |> Enum.flat_map(fn {field, messages} -> Enum.map(messages, &"#{field} #{&1}") end)
  end

  defp to_string_safe(value) when is_binary(value) or is_number(value) or is_atom(value),
    do: to_string(value)

  defp to_string_safe(value), do: inspect(value)

  # --- database failures -----------------------------------------------------------------

  # See the moduledoc. The broken-chain answer is outermost: a hash violation is not
  # retryable, so the inner rescue reraises it to the policy's one copy.
  @doc false
  @spec answering_database(Ecto.UUID.t(), %{dispatch_id: Ecto.UUID.t()}, String.t(), (-> r)) ::
          r | {:error, :busy | :audit_chain_append_failed}
        when r: term()
  def answering_database(tenant_id, message, write, fun) do
    RunnerStages.answering_broken_chain(
      tenant_id,
      fn -> "write=#{write} dispatch_id=#{message.dispatch_id}" end,
      fn -> answering_busy(tenant_id, message, write, fun) end
    )
  end

  defp answering_busy(tenant_id, message, write, fun) do
    fun.()
  rescue
    error in [Postgrex.Error, DBConnection.ConnectionError] ->
      if Stages.retryable_error?(error) do
        Logger.warning(
          "runner thread write gave up on the database and is answered busy: " <>
            "tenant_id=#{tenant_id} write=#{write} dispatch_id=#{message.dispatch_id} " <>
            "error=#{Exception.message(error)}"
        )

        {:error, :busy}
      else
        reraise error, __STACKTRACE__
      end
  end
end
