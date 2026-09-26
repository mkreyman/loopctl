defmodule Loopctl.Delivery.RunnerThreads do
  @moduledoc """
  Applies a runner's `checkpoint` and `thread_entry` messages to the story's change thread
  (epic 45, US-45.2, runner contract 1.20.0).

  A COORDINATOR, not a second writer, exactly as `Loopctl.Delivery.RunnerStages` is for
  `story_stages`: `Loopctl.Threads` stays the only thing that writes a thread, and the HTTP
  surface calls the same two functions with the same fence. What happens here is what the
  channel process should not carry:

  1. resolve the runner's dispatch to its story (`Loopctl.Runners.DispatchLedger`) — the
     story is NEVER taken off the wire — and refuse any kind but `implement` as
     `:unknown_dispatch`, as `session_ended` does: a triage session has no claim to report
     on. An entry needs the dispatch ACCEPTED. A checkpoint needs it accepted to write, but a
     RESEND of one is answered whatever the row's status, because the release that ends a
     claim lets a reply or trace mark the row `superseded` before the resend of a lost ack
     arrives, and the contract answers that resend from the row
     (`Loopctl.Threads.record_checkpoint/3`'s `:replay_only`);
  2. refuse an epoch that is not even the dispatch's, before a transaction is opened;
  3. resolve WHO is writing, from the server's own rows, never from the message;
  4. translate `Loopctl.Threads`' refusals into the reasons the contract publishes.

  ## Who the write is attributed to

  The principal is the runner's AGENT (`runners.agent_id`), spelled by
  `LoopctlWeb.ActorLabel.agent/1`, the same function `LoopctlWeb.ActorLabel.of/1` spells a
  key with an agent through. It has to be that agent:
  a placement claims the story AS the runner's agent (`Loopctl.Delivery.Placement`), so it is
  the identity `Loopctl.Delivery.Claimant` compares against `assigned_agent_id`, and it is the
  one a resend must repeat for `Loopctl.Threads` to recognise its own earlier write.

  The LINEAGE is the custody dispatch's — the session dispatch a placement minted and the
  claim recorded as `stories.implementer_dispatch_id` — and not the runner key's. The runner
  authenticates with its ENROLLMENT key, which no dispatch minted, so its own lineage is `[]`
  (`RunnerStages` states that, correctly, for its writes). A checkpoint attributed to `[]`
  would name no dispatch on the thread or on its audit-chain entry, on work a dispatch did.

  It is read on the RLS `Loopctl.Repo` in the tenant's transaction, and only while the story's
  `claim_epoch` is still the message's. After that, `implementer_dispatch_id` belongs to
  whichever claim came next, so the lineage is not this session's to take, and

  it resolves to `[]`, and nothing is written under that:

  - a `checkpoint` meets the claimant fence, which refuses a new write at an ended epoch; the
    one thing that passes is the recorder's own resend, which writes nothing;
  - a `thread_entry` carries the message's epoch into `Loopctl.Threads.record_entry/4`
    (`:claim_epoch`), which refuses it `:stale_claim_epoch` UNDER the story's lock, so a claim
    that moves between this read and the write is refused there, never written past. Because
    `implementer_dispatch_id` only changes with a claim, which bumps the epoch, a lineage read
    at epoch E is still E's once the lock confirms E. Its resend after the claim moved is
    refused too, and that is the right answer: the claim it reported on is over.

  A claim with no custody dispatch (a legacy claim no placement made) resolves to `[]`, which
  is what that claim genuinely has.

  ## A broken tenant chain

  Every write appends to the tenant's audit chain in its own transaction. A chain whose append
  trips its own HASH check raises, and raised inside the channel it would take the runner's
  socket down, every session on it with it, and the runner's resend would crash-loop it. It is
  answered `:audit_chain_append_failed` instead (`RunnerStages.answering_broken_chain/4`, the
  one copy of that policy), exactly as a `stage` is. Lock contention, a deadlock and a pool
  timeout never reach it: `Loopctl.Threads` answers those `:busy`.

  ## Retries

  Both are safe to repeat, because `Loopctl.Threads` makes them so: a checkpoint by
  `(commit_sha, claim_epoch)` and its recorder, an entry by its author and idempotency key,
  `<dispatch_id>:<client_seq>`. The reply says which it was (`replayed?`).
  """

  import Ecto.Query

  alias Loopctl.Delivery.RunnerStages
  alias Loopctl.Dispatches.Dispatch
  alias Loopctl.Repo
  alias Loopctl.Runners.DispatchLedger
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
  a checkpoint of the story `runner`'s accepted implement dispatch is for.
  """
  @spec record_checkpoint(Ecto.UUID.t(), runner(), map()) ::
          {:ok, %{checkpoint: Checkpoint.t(), replayed?: boolean()}} | {:error, error() | term()}
  def record_checkpoint(tenant_id, runner, %{} = message) do
    with {:ok, session} <- checkpoint_session(tenant_id, runner.id, message),
         {:ok, lineage} <- lineage(tenant_id, session.story_id, message.claim_epoch) do
      RunnerStages.answering_broken_chain(tenant_id, session.story_id, "write=checkpoint", fn ->
        Threads.record_checkpoint(tenant_id, session.story_id,
          agent_id: runner.agent_id,
          claim_epoch: message.claim_epoch,
          commit_sha: message.commit_sha,
          tree_sha: message.tree_sha,
          note: Map.get(message, :note),
          author_principal: principal(runner),
          actor_lineage: lineage,
          replay_only: session.status != "accepted"
        )
      end)
      |> answer(:checkpoint)
    end
  end

  @doc """
  Records `message` — already cast by `Loopctl.ApiSpec.RunnerContract.cast_thread_entry/1` —
  as a `message` entry on the thread of the story `runner`'s accepted implement dispatch is
  for, under the idempotency key `<dispatch_id>:<client_seq>`.
  """
  @spec record_entry(Ecto.UUID.t(), runner(), map()) ::
          {:ok, %{entry: Entry.t(), replayed?: boolean()}} | {:error, error() | term()}
  def record_entry(tenant_id, runner, %{} = message) do
    with {:ok, session} <- entry_session(tenant_id, runner.id, message),
         {:ok, lineage} <- lineage(tenant_id, session.story_id, message.claim_epoch) do
      attrs =
        %{
          "kind" => "message",
          "idempotency_key" => idempotency_key(message),
          "body" => message.body
        }
        |> put_checkpoint(Map.get(message, :checkpoint_id))

      RunnerStages.answering_broken_chain(tenant_id, session.story_id, "write=thread_entry", fn ->
        Threads.record_entry(tenant_id, session.story_id, attrs,
          author_principal: principal(runner),
          actor_lineage: lineage,
          claim_epoch: message.claim_epoch
        )
      end)
      |> answer(:entry)
    end
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

  # A note needs the dispatch accepted, resend or not: the claim it reports on is over once the
  # row has moved on, and the contract refuses it.
  defp entry_session(tenant_id, runner_id, message) do
    tenant_id
    |> DispatchLedger.accepted_session(runner_id, message.dispatch_id)
    |> implement_session(message)
  end

  # A checkpoint takes the row whatever its status; a row that is not `accepted` may only be
  # answered a resend (`:replay_only`), which writes nothing.
  defp checkpoint_session(tenant_id, runner_id, message) do
    tenant_id
    |> DispatchLedger.held_session(runner_id, message.dispatch_id)
    |> implement_session(message)
  end

  defp implement_session({:ok, session}, message) do
    with :ok <- implement_kind(session),
         :ok <- dispatch_epoch_matches(session, message),
         do: {:ok, session}
  end

  defp implement_session(error, _message), do: error

  # `nil` is a ledger row written before `kind` existed, when `implement` was the only kind
  # sent — the same reading `DispatchLedger`'s own implement check makes.
  defp implement_kind(%{kind: kind}) when kind in ["implement", nil], do: :ok
  defp implement_kind(_session), do: {:error, :unknown_dispatch}

  # Not the fence: `Loopctl.Threads` reads the story's epoch under its lock, which is what
  # decides. A message that does not even match the dispatch it names is refused here for the
  # cost of the read `accepted_session/3` already made.
  defp dispatch_epoch_matches(%{claim_epoch: epoch}, %{claim_epoch: epoch}), do: :ok
  defp dispatch_epoch_matches(_session, _message), do: {:error, :stale_claim_epoch}

  # --- the lineage -----------------------------------------------------------------------

  # The custody dispatch's lineage while the story's claim is still the message's, `[]` once it
  # is not; see the moduledoc for why nothing is written under the latter.
  # `implementer_dispatch_id` is a foreign key with no delete, so a declared dispatch always
  # resolves.
  defp lineage(tenant_id, story_id, epoch) do
    {:ok, row} =
      Repo.with_tenant(tenant_id, fn ->
        Repo.one(
          from s in Story,
            left_join: d in Dispatch,
            on: d.id == s.implementer_dispatch_id and d.tenant_id == s.tenant_id,
            where: s.id == ^story_id and s.tenant_id == ^tenant_id,
            select: {s.claim_epoch, d.lineage_path}
        )
      end)

    case row do
      {^epoch, lineage} -> {:ok, lineage || []}
      {_moved, _lineage} -> {:ok, []}
      # The ledger holds no foreign key to the story, so a deleted story leaves a dispatch
      # naming nothing — which is what `unknown_dispatch` says, permanently.
      nil -> {:error, :unknown_dispatch}
    end
  end

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

  # `:not_claimant`, `:stale_claim_epoch`, `:claim_not_live`, `:dispatch_not_accepted`,
  # `:busy` and `:audit_chain_append_failed` are published under their own names. Anything else reaches
  # `LoopctlWeb.RunnerChannel.Refusal`'s catch-all, which logs it and answers
  # `internal_error` — `Loopctl.Threads`' `:not_found` among them, which only a story deleted
  # between `custody_lineage/3` and the write can produce.
  defp classify(reason), do: reason

  defp unprocessable(%{code: "secret_blocked"}), do: :secret_blocked
  defp unprocessable(message) when is_binary(message), do: {:invalid, [message]}

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
end
