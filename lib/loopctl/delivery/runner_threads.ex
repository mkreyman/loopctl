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

  Step 1 is one read of the ledger row; step 3's lineage is resolved by `Loopctl.Threads`
  itself (`actor_lineage: :custody`), inside the write's transaction.

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
  `Loopctl.Threads` reads it on the story row it holds FOR SHARE, under the same lock as the
  fence, so it is always the lineage of the claim the write was fenced on. That claim must
  still be the message's for anything new to be written: a `checkpoint` meets the claimant
  fence, and a `thread_entry` carries its epoch in (`:claim_epoch`), refused
  `:stale_claim_epoch` under the lock once the claim moved. Either one's RESEND is answered
  from its row and writes nothing.

  ## Database failures, answered rather than raised

  Anything raised here is raised inside the runner channel's `handle_in`, where it takes down
  every session on the socket, and the runner's resend on rejoin crash-loops it. So:

  - contention on the ledger read is `:busy` (`Loopctl.Delivery.Stages.answering_busy/4`, the
    one copy of that policy), as `Loopctl.Threads` answers it on the write;
  - the tenant's audit chain refusing the append as a HASH violation is
    `:audit_chain_append_failed` (`RunnerStages.answering_broken_chain/3`, the one copy of
    that policy), exactly as a `stage` is.

  `:busy` asks for the same message again, which is safe: a write that did land before the
  connection was lost is answered from its row. Every other database error still raises.

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

  alias Loopctl.Delivery.RunnerStages
  alias Loopctl.Delivery.Stages
  alias Loopctl.Repo
  alias Loopctl.Runners.DispatchLedger
  alias Loopctl.Runners.DispatchRecord
  alias Loopctl.Threads
  alias Loopctl.Threads.Checkpoint
  alias Loopctl.Threads.Entry
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
    with {:ok, session} <- session(tenant_id, runner.id, message) do
      answering_broken_chain(tenant_id, message, "checkpoint", fn ->
        Threads.record_checkpoint(tenant_id, session.story_id,
          agent_id: runner.agent_id,
          claim_epoch: message.claim_epoch,
          commit_sha: message.commit_sha,
          tree_sha: message.tree_sha,
          note: Map.get(message, :note),
          author_principal: principal(runner),
          actor_lineage: :custody,
          replay_only: not session.accepted?
        )
      end)
      |> answer(:checkpoint)
    end
  end

  @doc """
  Records `message` — already cast by `Loopctl.ApiSpec.RunnerContract.cast_thread_entry/1` —
  as a `message` entry on the thread of the story `runner`'s implement dispatch is for, under
  the idempotency key `<dispatch_id>:<client_seq>`.
  """
  @spec record_entry(Ecto.UUID.t(), runner(), map()) ::
          {:ok, %{entry: Entry.t(), replayed?: boolean()}} | {:error, error() | term()}
  def record_entry(tenant_id, runner, %{} = message) do
    with {:ok, session} <- session(tenant_id, runner.id, message) do
      attrs =
        %{
          "kind" => "message",
          "idempotency_key" => idempotency_key(message),
          "body" => message.body
        }
        |> put_checkpoint(Map.get(message, :checkpoint_id))

      answering_broken_chain(tenant_id, message, "thread_entry", fn ->
        Threads.record_entry(tenant_id, session.story_id, attrs,
          author_principal: principal(runner),
          actor_lineage: :custody,
          claim_epoch: message.claim_epoch,
          replay_only: not session.accepted?
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

  # The ledger row `runner_id` holds for the message's dispatch, whatever its status. A row
  # another runner or tenant holds reads as none. Contention on the read is `:busy`.
  defp session(tenant_id, runner_id, message) do
    read = fn ->
      {:ok, row} =
        Repo.with_tenant(tenant_id, fn ->
          Repo.one(
            from r in DispatchRecord,
              where: r.tenant_id == ^tenant_id and r.runner_id == ^runner_id,
              where: r.dispatch_id == ^message.dispatch_id,
              select: %{
                status: r.status,
                kind: r.kind,
                story_id: r.story_id,
                claim_epoch: r.claim_epoch
              }
          )
        end)

      {:ok, row}
    end

    with {:ok, row} <-
           Stages.answering_busy(
             tenant_id,
             [:loopctl, :threads, :busy],
             "runner thread read",
             read
           ),
         {:ok, row} <- found(row),
         :ok <- implement_kind(row),
         :ok <- dispatch_epoch_matches(row, message) do
      {:ok, %{story_id: row.story_id, accepted?: row.status == "accepted"}}
    end
  end

  defp found(nil), do: {:error, :unknown_dispatch}
  defp found(row), do: {:ok, row}

  defp implement_kind(%{kind: kind}) do
    if DispatchLedger.implement_kind?(kind), do: :ok, else: {:error, :unknown_dispatch}
  end

  # Not the fence: `Loopctl.Threads` reads the story's epoch under its lock, which is what
  # decides. A message that does not even match the dispatch it names is refused here for the
  # cost of the read already made.
  defp dispatch_epoch_matches(%{claim_epoch: epoch}, %{claim_epoch: epoch}), do: :ok
  defp dispatch_epoch_matches(_row, _message), do: {:error, :stale_claim_epoch}

  defp put_checkpoint(attrs, nil), do: attrs
  defp put_checkpoint(attrs, checkpoint_id), do: Map.put(attrs, "checkpoint_id", checkpoint_id)

  # --- answers ---------------------------------------------------------------------------

  defp answer({:ok, record, status}, key),
    do: {:ok, %{key => record, replayed?: status == :existing}}

  defp answer({:error, reason}, _key), do: {:error, classify(reason)}
  defp answer({:error, :unprocessable_entity, detail}, _key), do: {:error, unprocessable(detail)}

  defp classify({:conflict, "checkpoint_conflict", _message}), do: :checkpoint_conflict
  defp classify({:conflict, "idempotency_key_reused", _message}), do: :idempotency_key_reused

  # The ledger holds no foreign key to the story, so a deleted story leaves a dispatch naming
  # nothing — which is what `unknown_dispatch` says, permanently.
  defp classify(:not_found), do: :unknown_dispatch

  defp classify(%Ecto.Changeset{data: %Entry{}} = changeset),
    do: {:invalid, changeset_messages(changeset)}

  # Every other reason passes through to `LoopctlWeb.RunnerChannel.Refusal`, which publishes
  # `:not_claimant`, `:stale_claim_epoch`, `:claim_not_live`, `:dispatch_not_accepted` and
  # `:audit_chain_append_failed` under their own names and `:busy` as `rate_limited` with a
  # retry interval. Anything it does not name reaches its catch-all, which logs it and answers
  # `internal_error`.
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

  # --- a broken chain -------------------------------------------------------------------

  defp answering_broken_chain(tenant_id, message, write, fun) do
    RunnerStages.answering_broken_chain(
      tenant_id,
      fn -> "write=#{write} dispatch_id=#{message.dispatch_id}" end,
      fun
    )
  end
end
