defmodule Loopctl.Threads do
  @moduledoc """
  A story's change thread (US-45.1, Epic 45 PRD §3): the checkpoints its claimant reported and
  the entries written around them. A thread is a story, 1:1, and outlives any one dispatch.

  ## What this module owns, and what it deliberately does not

  It owns the RECORD: checkpoints, and `message` / `review_requested` entries. It does not own
  JUDGEMENT. Findings, verdicts and the fixes that answer them decide what may merge, so they
  need an author loopctl can prove is not the implementer, and inferring that from the
  calling key — its agent, its lineage, whether it wrote a checkpoint — was reviewed three
  times and circumvented each time (#901). Those kinds arrive with US-45.3, where the author
  is a review dispatch loopctl itself placed for the thread.

  ## The checkpoint fence

  A checkpoint is recorded only for the story's CURRENT claimant (`Loopctl.Delivery.Claimant`)
  presenting the current `claim_epoch` while its lease is live. Git cannot see a claim, and a
  reclaimed runner can still push, so this is where the fence lives: loopctl never adopts a
  commit nobody reported, and never one reported under an ended claim. A checkpoint is keyed
  by `(commit_sha, claim_epoch)`, so a claimant resuming at a commit an ended claim recorded
  records it again under its own claim.

  ## Ordering, idempotency, scrubbing

  Every write takes a per-story advisory lock, then the story FOR SHARE (as
  `Loopctl.Delivery.Stages` does, so a release waits rather than committing between the fence
  check and the insert), then appends to the audit chain in the same transaction. Nothing
  takes those in another order. A read takes neither. A resend is idempotent only when it is
  the SAME write; a different write reusing a key or a checkpoint is refused. Every body is
  scanned by `Loopctl.Security.SecretDenylist` first, because an entry is hash-linked into
  the audit chain and could never be removed.
  """

  import Ecto.Query

  alias Loopctl.AuditChain
  alias Loopctl.Delivery.Claimant
  alias Loopctl.Repo
  alias Loopctl.Security.SecretDenylist
  alias Loopctl.Threads.Checkpoint
  alias Loopctl.Threads.Entry
  alias Loopctl.WorkBreakdown.Story

  @thread_lock_namespace :erlang.phash2(:loopctl_thread_ledger)
  @sha_pattern ~r/\A[0-9a-f]{40}([0-9a-f]{24})?\z/

  # Idempotency keys loopctl writes for its own entries. A caller may not use the prefix, so a
  # caller's key can never collide with the key a later checkpoint needs.
  @reserved_key_prefix "loopctl:"

  # A thread grows with every review round, and a whole one returned on every poll lands in
  # the caller's context each time, so entries are paged. Checkpoints are few and come whole.
  @default_entry_page 200
  @max_entry_page 500

  @story_fields [:id, :tenant_id, :assigned_agent_id, :claim_epoch, :claimed_until]

  @type thread :: %{
          checkpoints: [Checkpoint.t()],
          entries: [Entry.t()],
          next_after_seq: pos_integer() | nil
        }

  @doc """
  The story's thread: all of its checkpoints, and one page of its entries, each in `seq`
  order. `:after_seq` starts the page after that entry; `:limit` is capped at
  #{@max_entry_page}. `next_after_seq` is the `after_seq` for the next page, or nil on the
  last. `{:error, :not_found}` when the story is not visible to the tenant.
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

  @doc """
  Records a checkpoint for the story's current claimant.

  ## Options

  - `:agent_id` (required) — the calling key's agent, compared against `assigned_agent_id`
  - `:claim_epoch` (required) — the epoch the caller's claim returned
  - `:commit_sha`, `:tree_sha` (required) — lowercase hex, 40 or 64 characters
  - `:note` — the claimant's reasoning, stored as the checkpoint entry's body. Untrusted.
  - `:author_principal` (required), `:actor_lineage` (required) — SERVER-resolved from the key

  Returns `{:ok, checkpoint, :created | :existing}`.
  """
  @spec record_checkpoint(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, Checkpoint.t(), :created | :existing} | {:error, term()}
  def record_checkpoint(tenant_id, story_id, opts) do
    commit_sha = Keyword.fetch!(opts, :commit_sha)
    tree_sha = Keyword.fetch!(opts, :tree_sha)
    note = Keyword.get(opts, :note)

    with :ok <- valid_sha(commit_sha, "commit_sha"),
         :ok <- valid_sha(tree_sha, "tree_sha"),
         :ok <- valid_note(note),
         :ok <- no_secret(note) do
      in_story_lock(tenant_id, story_id, fn ->
        checkpoint_locked(tenant_id, story_id, commit_sha, tree_sha, opts)
      end)
    end
  end

  @doc """
  Records a `message` or `review_requested` entry on the story's thread, from any principal
  of the tenant. `attrs` carries `kind`, `idempotency_key`, `body` and an optional
  `checkpoint_id` of this story.

  ## Options

  - `:author_principal` (required), `:actor_lineage` (required) — SERVER-resolved from the key

  Returns `{:ok, entry, :created | :existing}`.
  """
  @spec record_entry(Ecto.UUID.t(), Ecto.UUID.t(), map(), keyword()) ::
          {:ok, Entry.t(), :created | :existing} | {:error, term()}
  def record_entry(tenant_id, story_id, attrs, opts) do
    changeset = Entry.changeset(%Entry{}, attrs)

    with :ok <- caller_kind(changeset),
         :ok <- reserved_key(changeset),
         :ok <- no_secret(Ecto.Changeset.get_field(changeset, :body)) do
      in_story_lock(tenant_id, story_id, fn ->
        entry_locked(tenant_id, story_id, changeset, opts)
      end)
    end
  end

  # ---------------------------------------------------------------------------
  # Reads
  # ---------------------------------------------------------------------------

  defp read_thread(tenant_id, story_id, opts) do
    if Repo.one(story_query(tenant_id, story_id)) do
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

  defp story_query(tenant_id, story_id) do
    from s in Story,
      where: s.id == ^story_id and s.tenant_id == ^tenant_id,
      select: struct(s, ^@story_fields)
  end

  defp locked_story(tenant_id, story_id),
    do: Repo.one(story_query(tenant_id, story_id) |> lock("FOR SHARE"))

  # ---------------------------------------------------------------------------
  # Checkpoints
  # ---------------------------------------------------------------------------

  defp checkpoint_locked(tenant_id, story_id, commit_sha, tree_sha, opts) do
    epoch = Keyword.fetch!(opts, :claim_epoch)

    with :ok <- claimant(tenant_id, story_id, Keyword.fetch!(opts, :agent_id), epoch) do
      case checkpoint_by_sha(tenant_id, story_id, commit_sha, epoch) do
        nil -> insert_checkpoint(tenant_id, story_id, commit_sha, tree_sha, opts)
        existing -> replay_checkpoint(existing, tree_sha, Keyword.get(opts, :note))
      end
    end
  end

  defp claimant(tenant_id, story_id, agent_id, epoch) do
    case locked_story(tenant_id, story_id) do
      nil ->
        {:error, :not_found}

      story ->
        with :ok <- Claimant.check(story, agent_id, epoch), do: lease(story)
    end
  end

  defp lease(story) do
    if Claimant.lease_live?(story, DateTime.utc_now()),
      do: :ok,
      else: {:error, :claim_not_live}
  end

  # The same checkpoint, resent: the tree must match, and a note, when sent, must be the one
  # recorded. Anything else is a different write, refused rather than acknowledged.
  defp replay_checkpoint(%Checkpoint{tree_sha: tree_sha} = existing, tree_sha, note) do
    if is_nil(note) or note == checkpoint_note(existing),
      do: {:ok, existing, :existing, []},
      else: conflict("checkpoint_conflict", "commit_sha is already recorded with another note")
  end

  defp replay_checkpoint(_existing, _tree_sha, _note),
    do: conflict("checkpoint_conflict", "commit_sha is already recorded with another tree_sha")

  defp checkpoint_note(checkpoint) do
    Repo.one(
      from e in Entry,
        where: e.checkpoint_id == ^checkpoint.id and e.kind == :checkpoint,
        select: e.body
    )
  end

  defp insert_checkpoint(tenant_id, story_id, commit_sha, tree_sha, opts) do
    lineage = Keyword.fetch!(opts, :actor_lineage)
    epoch = Keyword.fetch!(opts, :claim_epoch)
    previous = latest_checkpoint(tenant_id, story_id)

    checkpoint =
      Repo.insert!(%Checkpoint{
        tenant_id: tenant_id,
        story_id: story_id,
        seq: if(previous, do: previous.seq + 1, else: 1),
        commit_sha: commit_sha,
        tree_sha: tree_sha,
        parent_checkpoint_id: previous && previous.id,
        claim_epoch: epoch,
        dispatch_id: List.last(lineage)
      })

    entry =
      Entry.system_changeset(%{
        kind: :checkpoint,
        idempotency_key: @reserved_key_prefix <> "checkpoint:#{commit_sha}:#{epoch}",
        body: Keyword.get(opts, :note) || "checkpoint #{commit_sha}",
        checkpoint_id: checkpoint.id
      })

    with {:ok, _entry, :created, chained} <- insert_entry(tenant_id, story_id, entry, opts) do
      {:ok, checkpoint, :created, chained}
    end
  end

  defp checkpoint_by_sha(tenant_id, story_id, commit_sha, epoch) do
    Repo.one(
      from c in Checkpoint,
        where:
          c.tenant_id == ^tenant_id and c.story_id == ^story_id and c.commit_sha == ^commit_sha and
            c.claim_epoch == ^epoch
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

  defp valid_sha(value, field) do
    if is_binary(value) and Regex.match?(@sha_pattern, value),
      do: :ok,
      else: {:error, :unprocessable_entity, "#{field} must be 40 or 64 lowercase hex characters"}
  end

  defp valid_note(nil), do: :ok

  defp valid_note(note) when is_binary(note) and note != "" do
    if byte_size(note) <= Entry.max_body_bytes(),
      do: :ok,
      else:
        {:error, :unprocessable_entity, "note must be at most #{Entry.max_body_bytes()} bytes"}
  end

  defp valid_note(_note), do: {:error, :unprocessable_entity, "note must be a non-empty string"}

  # ---------------------------------------------------------------------------
  # Entries
  # ---------------------------------------------------------------------------

  defp caller_kind(changeset) do
    kind = Ecto.Changeset.get_field(changeset, :kind)

    cond do
      not changeset.valid? ->
        {:error, changeset}

      kind in Entry.caller_kinds() ->
        :ok

      kind in [:finding, :fix, :verdict] ->
        {:error, :unprocessable_entity,
         "kind #{kind} is written by a review dispatch (US-45.3), not through this endpoint"}

      true ->
        {:error, :unprocessable_entity, "kind #{kind} is written by loopctl, not a caller"}
    end
  end

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
           message: "the text carries a credential-shaped value and was not recorded"
         }},
      else: :ok
  end

  defp entry_locked(tenant_id, story_id, changeset, opts) do
    author = Keyword.fetch!(opts, :author_principal)
    key = Ecto.Changeset.get_field(changeset, :idempotency_key)

    with {:story, %Story{}} <- {:story, locked_story(tenant_id, story_id)},
         nil <- entry_by_key(tenant_id, story_id, author, key),
         :ok <- checkpoint_of_story(changeset, tenant_id, story_id) do
      insert_entry(tenant_id, story_id, changeset, opts)
    else
      {:story, nil} -> {:error, :not_found}
      %Entry{} = existing -> replay(existing, changeset)
      error -> error
    end
  end

  defp entry_by_key(tenant_id, story_id, author, key) do
    Repo.one(
      from e in Entry,
        where:
          e.tenant_id == ^tenant_id and e.story_id == ^story_id and
            e.author_principal == ^author and e.idempotency_key == ^key
    )
  end

  # A resend is the SAME write: every caller field must match what was stored. A different
  # write reusing a key is refused rather than acknowledged with the old row, which would tell
  # the caller its new entry was recorded when it was not. `checkpoint_id` is an `Ecto.UUID`,
  # so the caller's value and the stored one are compared in one canonical form.
  @replayed_fields [:kind, :body, :checkpoint_id]

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

  defp checkpoint_of_story(changeset, tenant_id, story_id) do
    case Ecto.Changeset.get_field(changeset, :checkpoint_id) do
      nil ->
        :ok

      checkpoint_id ->
        if Repo.exists?(
             from c in Checkpoint,
               where:
                 c.id == ^checkpoint_id and c.tenant_id == ^tenant_id and
                   c.story_id == ^story_id
           ),
           do: :ok,
           else:
             {:error, :unprocessable_entity, "checkpoint_id is not a checkpoint of this story"}
    end
  end

  defp insert_entry(tenant_id, story_id, changeset, opts) do
    lineage = Keyword.fetch!(opts, :actor_lineage)

    changeset =
      changeset
      |> Ecto.Changeset.put_change(:tenant_id, tenant_id)
      |> Ecto.Changeset.put_change(:story_id, story_id)
      |> Ecto.Changeset.put_change(:seq, next_entry_seq(tenant_id, story_id))
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

  defp conflict(code, message), do: {:error, {:conflict, code, message}}

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

  defp next_entry_seq(tenant_id, story_id) do
    Repo.one(
      from e in Entry,
        where: e.tenant_id == ^tenant_id and e.story_id == ^story_id,
        select: coalesce(max(e.seq), 0)
    ) + 1
  end
end
