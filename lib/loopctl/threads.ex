defmodule Loopctl.Threads do
  @moduledoc """
  A story's change thread (US-45.1, Epic 45 PRD §3): the checkpoints its claimant reported and
  the entries written around them. A thread is a story, 1:1, and outlives any one dispatch.

  ## What is fenced, and where

  A **checkpoint** is recorded only for the story's CURRENT claimant presenting the story's
  current `claim_epoch`. Git cannot see a claim epoch, and a reclaimed runner can still push,
  so this is where the fence lives: loopctl never adopts a commit nobody reported, and never
  one reported under an ended claim.

  An **entry** is authorized by its kind (US-45.1 AC-10):

  - `finding` and `verdict` are JUDGEMENTS, refused (`implementer_cannot_judge`) from the story's
    assigned agent and from any caller whose lineage is on the implementer's dispatch chain —
    the same separation `review-complete` draws. A verdict entry is what completes a review
    round, so an implementer able to write one could grant itself the round it needed.
  - `fix` is the CLAIMANT's, fenced by `claim_epoch` exactly as a checkpoint is, so a runner
    whose claim ended cannot keep feeding the next reviewer "reasons".
  - `message` and `review_requested` are open to every principal of the tenant.

  `checkpoint` entries are written here beside the checkpoint they describe, and `escalation`
  and `merge` entries belong to the flows that perform those acts. Every body is scanned by
  `Loopctl.Security.SecretDenylist` first: an entry is hash-linked into the audit chain, so a
  credential that reached one could never be removed.

  ## Ordering and idempotency

  Every write takes a per-story advisory lock before it reads, so `seq` is gap-free per story
  and the lookup-then-insert that makes a retry idempotent cannot race another writer. The
  lock is taken BEFORE the audit chain's own lock and nothing takes them in the other order.
  A resent entry with the same `(author_principal, idempotency_key)` returns the row already
  written; a resent checkpoint with the same `commit_sha` does too.

  Every write appends an audit-chain entry inside the same transaction, so the ledger and the
  chain commit or roll back together.
  """

  import Ecto.Query

  alias Loopctl.AuditChain
  alias Loopctl.Dispatches
  alias Loopctl.Dispatches.Dispatch
  alias Loopctl.Repo
  alias Loopctl.Security.SecretDenylist
  alias Loopctl.Threads.Checkpoint
  alias Loopctl.Threads.Entry
  alias Loopctl.WorkBreakdown.Story

  @thread_lock_namespace :erlang.phash2(:loopctl_thread_ledger)

  # Idempotency keys loopctl writes for its own entries. A caller may not use the prefix, so a
  # caller's key can never collide with the key a later checkpoint needs.
  @reserved_key_prefix "loopctl:"
  @sha_pattern ~r/\A[0-9a-f]{40}([0-9a-f]{24})?\z/

  @type thread :: %{
          checkpoints: [Checkpoint.t()],
          entries: [Entry.t()],
          next_after_seq: pos_integer() | nil
        }

  # A thread grows with every review round, and a whole one returned on every poll lands in
  # the caller's context each time, so entries are paged. Checkpoints are few and come whole.
  @default_entry_page 200
  @max_entry_page 500

  @doc """
  The story's thread: all of its checkpoints, and one page of its entries, each in `seq`
  order. `:after_seq` starts the page after that entry; `:limit` is capped at
  #{@max_entry_page}. `next_after_seq` is the `after_seq` for the next page, or nil when this
  page is the last. `{:error, :not_found}` when the story is not visible to the tenant.
  """
  @spec get_thread(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, thread()} | {:error, :not_found}
  def get_thread(tenant_id, story_id, opts \\ []) do
    {:ok, result} =
      Repo.with_tenant(tenant_id, fn -> read_thread(tenant_id, story_id, opts) end)

    result
  end

  @doc "The largest page of entries `get_thread/3` returns."
  @spec max_entry_page() :: pos_integer()
  def max_entry_page, do: @max_entry_page

  defp read_thread(tenant_id, story_id, opts) do
    if entry_story(tenant_id, story_id) do
      limit = opts |> Keyword.get(:limit, @default_entry_page) |> max(1) |> min(@max_entry_page)
      after_seq = Keyword.get(opts, :after_seq, 0)

      entries =
        Entry
        |> in_story(tenant_id, story_id)
        |> where([e], e.seq > ^after_seq)
        |> limit(^(limit + 1))
        |> Repo.all()

      {page, rest} = Enum.split(entries, limit)

      {:ok,
       %{
         checkpoints: Repo.all(in_story(Checkpoint, tenant_id, story_id)),
         entries: page,
         next_after_seq: if(rest == [], do: nil, else: List.last(page).seq)
       }}
    else
      {:error, :not_found}
    end
  end

  defp in_story(schema, tenant_id, story_id) do
    from r in schema,
      where: r.tenant_id == ^tenant_id and r.story_id == ^story_id,
      order_by: r.seq
  end

  @doc """
  Records a checkpoint for the story's current claimant.

  ## Options

  - `:agent_id` (required) — the calling key's agent, compared against `assigned_agent_id`
  - `:claim_epoch` (required) — the epoch the caller's claim returned
  - `:commit_sha`, `:tree_sha` (required) — lowercase hex, 40 or 64 characters
  - `:note` — the claimant's reasoning for this checkpoint, stored as the checkpoint entry's
    body. Untrusted.
  - `:author_principal` (required), `:actor_lineage` (required) — SERVER-resolved from the key

  Returns `{:ok, checkpoint, :created | :existing}`.
  """
  @spec record_checkpoint(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, Checkpoint.t(), :created | :existing} | {:error, term()}
  def record_checkpoint(tenant_id, story_id, opts) do
    commit_sha = Keyword.fetch!(opts, :commit_sha)
    tree_sha = Keyword.fetch!(opts, :tree_sha)

    with :ok <- valid_sha(commit_sha, "commit_sha"),
         :ok <- valid_sha(tree_sha, "tree_sha"),
         :ok <- no_secret(Keyword.get(opts, :note)) do
      in_story_lock(tenant_id, story_id, fn ->
        checkpoint_locked(tenant_id, story_id, commit_sha, tree_sha, opts)
      end)
    end
  end

  @doc """
  Records an entry on the story's thread.

  `attrs` carries the caller's fields (`kind`, `idempotency_key`, `body`, and, by kind,
  `checkpoint_id`, `finding_ids`, `introduced_by`, `severity`).

  ## Options

  - `:author_principal` (required), `:actor_lineage` (required), `:agent_id` — SERVER-resolved
    from the key
  - `:claim_epoch` — required for a `fix`, the epoch the caller's claim returned

  Returns `{:ok, entry, :created | :existing}`.
  """
  @spec record_entry(Ecto.UUID.t(), Ecto.UUID.t(), map(), keyword()) ::
          {:ok, Entry.t(), :created | :existing} | {:error, term()}
  def record_entry(tenant_id, story_id, attrs, opts) do
    author = Keyword.fetch!(opts, :author_principal)
    changeset = Entry.changeset(%Entry{}, attrs)

    with :ok <- caller_kind(changeset),
         :ok <- reserved_key(changeset),
         :ok <- no_secret(Ecto.Changeset.get_field(changeset, :body)) do
      in_story_lock(tenant_id, story_id, fn ->
        entry_locked(tenant_id, story_id, author, attrs, changeset, opts)
      end)
    end
  end

  # ---------------------------------------------------------------------------
  # Checkpoints
  # ---------------------------------------------------------------------------

  defp checkpoint_locked(tenant_id, story_id, commit_sha, tree_sha, opts) do
    with :ok <-
           claimant(
             tenant_id,
             story_id,
             Keyword.fetch!(opts, :agent_id),
             Keyword.fetch!(opts, :claim_epoch)
           ) do
      case checkpoint_by_sha(tenant_id, story_id, commit_sha) do
        %Checkpoint{tree_sha: ^tree_sha} = existing ->
          {:ok, existing, :existing, []}

        %Checkpoint{} ->
          conflict(
            "checkpoint_conflict",
            "commit_sha is already recorded with a different tree_sha"
          )

        nil ->
          insert_checkpoint(tenant_id, story_id, commit_sha, tree_sha, opts)
      end
    end
  end

  defp insert_checkpoint(tenant_id, story_id, commit_sha, tree_sha, opts) do
    lineage = Keyword.fetch!(opts, :actor_lineage)
    previous = latest_checkpoint(tenant_id, story_id)

    checkpoint =
      Repo.insert!(%Checkpoint{
        tenant_id: tenant_id,
        story_id: story_id,
        seq: if(previous, do: previous.seq + 1, else: 1),
        commit_sha: commit_sha,
        tree_sha: tree_sha,
        parent_checkpoint_id: previous && previous.id,
        claim_epoch: Keyword.fetch!(opts, :claim_epoch),
        dispatch_id: List.last(lineage)
      })

    note = Keyword.get(opts, :note) || "checkpoint #{commit_sha}"

    entry_changeset =
      Entry.changeset(%Entry{}, %{
        kind: :checkpoint,
        idempotency_key: @reserved_key_prefix <> "checkpoint:" <> commit_sha,
        body: note,
        checkpoint_id: checkpoint.id
      })

    with {:ok, _entry, :created, chained} <-
           insert_entry(tenant_id, story_id, entry_changeset, opts) do
      {:ok, checkpoint, :created, chained}
    end
  end

  defp checkpoint_by_sha(tenant_id, story_id, commit_sha) do
    Repo.one(
      from c in Checkpoint,
        where:
          c.tenant_id == ^tenant_id and c.story_id == ^story_id and c.commit_sha == ^commit_sha
    )
  end

  defp latest_checkpoint(tenant_id, story_id) do
    Repo.one(
      from c in Checkpoint,
        where: c.tenant_id == ^tenant_id and c.story_id == ^story_id,
        order_by: [desc: c.seq],
        limit: 1
    )
  end

  defp valid_sha(value, field) when is_binary(value) do
    if Regex.match?(@sha_pattern, value),
      do: :ok,
      else: {:error, :unprocessable_entity, "#{field} must be 40 or 64 lowercase hex characters"}
  end

  defp valid_sha(_value, field),
    do: {:error, :unprocessable_entity, "#{field} must be 40 or 64 lowercase hex characters"}

  # The same rule `Loopctl.Delivery.Escalations` applies to the claimant: both halves of the
  # comparison must be a real agent, so an unclaimed story never matches a key with no agent.
  defp claimant(tenant_id, story_id, agent_id, epoch) do
    case entry_story(tenant_id, story_id) do
      nil -> {:error, :not_found}
      story -> claimant_of(story, agent_id, epoch)
    end
  end

  defp claimant_of(story, agent_id, epoch) do
    cond do
      is_nil(story.assigned_agent_id) or is_nil(agent_id) -> {:error, :not_claimant}
      story.assigned_agent_id != agent_id -> {:error, :not_claimant}
      story.claim_epoch != epoch -> {:error, :stale_claim_epoch}
      true -> :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Entries
  # ---------------------------------------------------------------------------

  defp caller_kind(changeset) do
    kind = Ecto.Changeset.get_field(changeset, :kind)

    cond do
      not changeset.valid? -> {:error, changeset}
      kind in Entry.caller_kinds() -> :ok
      true -> {:error, :unprocessable_entity, "kind #{kind} is written by loopctl, not a caller"}
    end
  end

  defp entry_locked(tenant_id, story_id, author, attrs, changeset, opts) do
    with {:story, %{} = story} <- {:story, entry_story(tenant_id, story_id)},
         nil <- entry_by_key(tenant_id, story_id, author, attrs),
         :ok <- author_may_write(story, changeset, opts),
         {:ok, changeset} <- apply_references(changeset, story) do
      insert_entry(tenant_id, story_id, changeset, opts)
    else
      {:story, nil} -> {:error, :not_found}
      %Entry{} = existing -> replay(existing, changeset)
      error -> error
    end
  end

  # A resend is the SAME write: every caller field must match what was stored. A different
  # write reusing a key is refused rather than acknowledged with the old row, which would tell
  # the caller its new entry was recorded when it was not.
  @replayed_fields [:kind, :body, :checkpoint_id, :finding_ids, :introduced_by, :severity]

  defp replay(existing, changeset) do
    same? =
      Enum.all?(@replayed_fields, fn field ->
        Map.get(existing, field) == Ecto.Changeset.get_field(changeset, field)
      end)

    if same?,
      do: {:ok, existing, :existing, []},
      else:
        conflict(
          "idempotency_key_reused",
          "idempotency_key already names a different entry by this author"
        )
  end

  defp conflict(code, message), do: {:error, {:conflict, code, message}}

  defp reserved_key(changeset) do
    key = Ecto.Changeset.get_field(changeset, :idempotency_key) || ""

    if String.starts_with?(key, @reserved_key_prefix),
      do:
        {:error, :unprocessable_entity,
         "idempotency_key may not start with #{@reserved_key_prefix}"},
      else: :ok
  end

  defp no_secret(body) do
    if SecretDenylist.contains_secret?(body),
      do:
        {:error, :unprocessable_entity,
         %{
           code: "secret_blocked",
           message: "body carries a credential-shaped value and was not recorded"
         }},
      else: :ok
  end

  # FOR SHARE, as `Loopctl.Delivery.Stages` takes it: a release or reclaim takes the story
  # FOR UPDATE to end a claim, so it waits for this transaction instead of committing between
  # the fence check and the insert. The per-story thread lock is taken before this and by no
  # path that holds the story lock, so the order cannot invert.
  defp entry_story(tenant_id, story_id) do
    Repo.one(
      from s in Story,
        where: s.id == ^story_id and s.tenant_id == ^tenant_id,
        lock: "FOR SHARE",
        select: %{
          id: s.id,
          tenant_id: s.tenant_id,
          assigned_agent_id: s.assigned_agent_id,
          claim_epoch: s.claim_epoch,
          implementer_dispatch_id: s.implementer_dispatch_id
        }
    )
  end

  defp author_may_write(story, changeset, opts) do
    case Ecto.Changeset.get_field(changeset, :kind) do
      kind when kind in [:finding, :verdict] -> not_the_implementer(story, opts)
      :fix -> claimant_of(story, Keyword.get(opts, :agent_id), Keyword.get(opts, :claim_epoch))
      _open -> :ok
    end
  end

  # Refused with its OWN code, never `self_review_blocked`: that code is an L6 custody signal
  # the fallback counts toward a tenant-wide halt, and an implementer mis-filing its own notes
  # as a finding — or its client retrying one — must not be able to halt the tenant.
  #
  # An EMPTY caller lineage on dispatch-minted work is refused unless the caller is a human
  # (`:user` role, no agent), the same permit `review-complete` draws: a legacy key no
  # dispatch minted, in the implementer's own process, would otherwise grant it the round.
  defp not_the_implementer(story, opts) do
    agent_id = Keyword.get(opts, :agent_id)
    lineage = Keyword.fetch!(opts, :actor_lineage)

    cond do
      not is_nil(agent_id) and agent_id == story.assigned_agent_id ->
        implementer_cannot_judge()

      is_nil(story.implementer_dispatch_id) ->
        :ok

      lineage == [] and human?(agent_id, Keyword.get(opts, :actor_role)) ->
        :ok

      lineage == [] ->
        {:error, :caller_lineage_required}

      true ->
        # Read on the RLS repo inside this transaction, not `Dispatches.get_dispatch/2`, which
        # checks out one of AdminRepo's three connections for a read every judgement makes.
        # A declared implementer dispatch that cannot be read fails CLOSED.
        story |> implementer_lineage() |> separated_from(lineage)
    end
  end

  defp separated_from([], _caller), do: {:error, :unresolvable_dispatch_lineage}

  defp separated_from(impl, caller) do
    if Dispatches.lineage_same_chain?(impl, caller),
      do: implementer_cannot_judge(),
      else: :ok
  end

  defp implementer_cannot_judge,
    do:
      conflict(
        "implementer_cannot_judge",
        "the story's implementer, or a dispatch on its chain, cannot write a finding or verdict"
      )

  defp human?(nil, role) when role in [:user, :superadmin], do: true
  defp human?(_agent_id, _role), do: false

  defp implementer_lineage(story) do
    Repo.one(
      from d in Dispatch,
        where: d.id == ^story.implementer_dispatch_id and d.tenant_id == ^story.tenant_id,
        select: d.lineage_path
    ) || []
  end

  defp entry_by_key(tenant_id, story_id, author, attrs) do
    case attrs["idempotency_key"] || attrs[:idempotency_key] do
      key when is_binary(key) ->
        Repo.one(
          from e in Entry,
            where:
              e.tenant_id == ^tenant_id and e.story_id == ^story_id and
                e.author_principal == ^author and e.idempotency_key == ^key
        )

      _ ->
        nil
    end
  end

  # What each kind must point at, checked against THIS story's rows so no entry can reference
  # another story's checkpoint or finding.
  defp apply_references(changeset, story) do
    tenant_id = story.tenant_id
    story_id = story.id

    kind = Ecto.Changeset.get_field(changeset, :kind)
    checkpoint_id = Ecto.Changeset.get_field(changeset, :checkpoint_id)
    finding_ids = Ecto.Changeset.get_field(changeset, :finding_ids) || []
    introduced_by = Ecto.Changeset.get_field(changeset, :introduced_by)

    with :ok <- severity_rule(Ecto.Changeset.get_field(changeset, :severity), kind),
         :ok <- checkpoint_of_story(checkpoint_id, kind, tenant_id, story_id),
         :ok <- findings_of_story(finding_ids, kind, tenant_id, story_id),
         :ok <- introduced_by_rule(introduced_by, kind, tenant_id, story_id),
         :ok <- fix_follows_findings(kind, checkpoint_id, finding_ids, story) do
      {:ok, changeset}
    end
  end

  # A fix is carried by a checkpoint of the CURRENT claim, recorded after every checkpoint its
  # findings were found in: code that predates a finding cannot have fixed it.
  defp fix_follows_findings(:fix, _checkpoint_id, [], _story), do: :ok

  defp fix_follows_findings(:fix, checkpoint_id, finding_ids, story) do
    fix_cp =
      Repo.one(
        from c in Checkpoint,
          where: c.id == ^checkpoint_id and c.tenant_id == ^story.tenant_id,
          select: %{seq: c.seq, claim_epoch: c.claim_epoch}
      )

    found_at =
      Repo.one(
        from e in Entry,
          join: c in Checkpoint,
          on: c.id == e.checkpoint_id,
          where: e.tenant_id == ^story.tenant_id and e.id in ^finding_ids,
          select: max(c.seq)
      )

    cond do
      fix_cp.claim_epoch != story.claim_epoch ->
        {:error, :unprocessable_entity,
         "a fix must be carried by a checkpoint of the current claim"}

      fix_cp.seq <= found_at ->
        {:error, :unprocessable_entity,
         "a fix must be carried by a checkpoint recorded after the findings it answers"}

      true ->
        :ok
    end
  end

  defp fix_follows_findings(_kind, _checkpoint_id, _finding_ids, _story), do: :ok

  defp checkpoint_of_story(nil, :finding, _tenant_id, _story_id),
    do: {:error, :unprocessable_entity, "a finding must name the checkpoint it was found in"}

  defp checkpoint_of_story(nil, :fix, _tenant_id, _story_id),
    do: {:error, :unprocessable_entity, "a fix must name the checkpoint that carries it"}

  defp checkpoint_of_story(nil, _kind, _tenant_id, _story_id), do: :ok

  defp checkpoint_of_story(checkpoint_id, _kind, tenant_id, story_id) do
    if checkpoint_in_story?(checkpoint_id, tenant_id, story_id),
      do: :ok,
      else: {:error, :unprocessable_entity, "checkpoint_id is not a checkpoint of this story"}
  end

  defp findings_of_story([], :fix, _tenant_id, _story_id),
    do: {:error, :unprocessable_entity, "a fix must name the findings it answers"}

  defp findings_of_story([], _kind, _tenant_id, _story_id), do: :ok

  defp findings_of_story(ids, _kind, tenant_id, story_id) do
    ids = Enum.uniq(ids)

    found =
      Repo.one(
        from e in Entry,
          where:
            e.tenant_id == ^tenant_id and e.story_id == ^story_id and e.kind == :finding and
              e.id in ^ids,
          select: count(e.id)
      )

    if found == length(ids),
      do: :ok,
      else: {:error, :unprocessable_entity, "finding_ids must all be findings of this story"}
  end

  defp severity_rule(nil, :finding),
    do: {:error, :unprocessable_entity, "a finding must carry a severity"}

  defp severity_rule(_severity, _kind), do: :ok

  # After the first completed review round, every finding must say whether a checkpoint
  # introduced it — `none` included — so the third-round rule is decidable from data.
  defp introduced_by_rule(nil, :finding, tenant_id, story_id) do
    if completed_rounds(tenant_id, story_id) > 0,
      do:
        {:error, :unprocessable_entity,
         "introduced_by is required on a finding after the first completed review round"},
      else: :ok
  end

  defp introduced_by_rule(nil, _kind, _tenant_id, _story_id), do: :ok
  defp introduced_by_rule("none", _kind, _tenant_id, _story_id), do: :ok

  defp introduced_by_rule(checkpoint_id, _kind, tenant_id, story_id) do
    if checkpoint_in_story?(checkpoint_id, tenant_id, story_id),
      do: :ok,
      else: {:error, :unprocessable_entity, "introduced_by is not a checkpoint of this story"}
  end

  defp checkpoint_in_story?(checkpoint_id, tenant_id, story_id) do
    Repo.exists?(
      from c in Checkpoint,
        where: c.id == ^checkpoint_id and c.tenant_id == ^tenant_id and c.story_id == ^story_id
    )
  end

  # A round is complete when a non-implementer writes a verdict entry (`author_may_write/3`
  # refuses one from the implementer). `review_records` rows belong to the custody lifecycle,
  # which a thread's rounds do not pass through, and are not counted.
  defp completed_rounds(tenant_id, story_id) do
    Repo.one(
      from e in Entry,
        where: e.tenant_id == ^tenant_id and e.story_id == ^story_id and e.kind == :verdict,
        select: count(e.id)
    )
  end

  defp insert_entry(tenant_id, story_id, changeset, opts) do
    lineage = Keyword.fetch!(opts, :actor_lineage)

    changeset =
      changeset
      |> Ecto.Changeset.put_change(:tenant_id, tenant_id)
      |> Ecto.Changeset.put_change(:story_id, story_id)
      |> Ecto.Changeset.put_change(:seq, next_seq(Entry, tenant_id, story_id))
      |> Ecto.Changeset.put_change(:author_principal, Keyword.fetch!(opts, :author_principal))
      |> Ecto.Changeset.put_change(:dispatch_id, List.last(lineage))

    with {:ok, entry} <- Repo.insert(changeset),
         {:ok, chain_entry} <- chain(tenant_id, story_id, entry, lineage) do
      {:ok, entry, :created, [chain_entry]}
    end
  end

  defp chain(tenant_id, story_id, entry, lineage) do
    AuditChain.append_in_tenant_transaction(tenant_id, %{
      action: "thread_#{entry.kind}_recorded",
      actor_lineage: lineage,
      entity_type: "story",
      entity_id: story_id,
      payload: %{
        "thread_entry_id" => entry.id,
        "seq" => entry.seq,
        "kind" => to_string(entry.kind),
        "author_principal" => entry.author_principal,
        "checkpoint_id" => entry.checkpoint_id
      }
    })
  end

  # ---------------------------------------------------------------------------
  # Transaction and ordering
  # ---------------------------------------------------------------------------

  # `fun` answers `{:ok, value, status, chain_entries}`; the chain entries are announced only
  # once the transaction that wrote them has committed.
  defp in_story_lock(tenant_id, story_id, fun) do
    result =
      Repo.with_tenant(tenant_id, fn ->
        Repo.query!("SELECT pg_advisory_xact_lock($1::int, hashtext($2))", [
          @thread_lock_namespace,
          story_id
        ])

        case fun.() do
          {:ok, _, _, _} = ok -> ok
          error -> Repo.rollback(error)
        end
      end)

    case result do
      {:ok, {:ok, value, status, chained}} ->
        Enum.each(chained, &AuditChain.announce_entry/1)
        {:ok, value, status}

      {:error, error} ->
        error
    end
  end

  defp next_seq(schema, tenant_id, story_id) do
    Repo.one(
      from r in schema,
        where: r.tenant_id == ^tenant_id and r.story_id == ^story_id,
        select: coalesce(max(r.seq), 0)
    ) + 1
  end
end
