defmodule Loopctl.Threads do
  @moduledoc """
  A story's change thread (US-45.1, Epic 45 PRD §3): the checkpoints its claimant reported and
  the entries written around them. A thread is a story, 1:1, and outlives any one dispatch.

  ## What this module owns, and what it deliberately does not

  It owns the RECORD: checkpoints and `message` entries, and the write path every entry takes.
  It does not own JUDGEMENT. Findings, verdicts and the fixes that answer them decide what may
  merge, so they need an author loopctl can prove is not the implementer, and inferring that
  from the calling key — its agent, its lineage, whether it wrote a checkpoint — was reviewed
  three times and circumvented each time (#901). `Loopctl.Threads.Reviews` writes those kinds
  (US-45.3), through the `@doc false` helpers below, and its author is a review dispatch
  loopctl itself placed for the thread.

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
  the SAME write; a different write reusing a key or a checkpoint is refused. Every body, note
  and idempotency key is scanned by `Loopctl.Security.SecretDenylist` first: an entry is
  served to every role of the tenant and there is no path to edit or remove one. The audit
  chain records each write's id, seq, kind, author and checkpoint, NOT its body, so the chain
  proves an entry was written, not what it said.
  """

  import Ecto.Query

  require Logger

  alias Loopctl.AuditChain
  alias Loopctl.Delivery.Claimant
  alias Loopctl.Delivery.Stages
  alias Loopctl.Dispatches.Dispatch
  alias Loopctl.Repo
  alias Loopctl.Runners.Capacity
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

  @story_fields [
    :id,
    :tenant_id,
    :assigned_agent_id,
    :claim_epoch,
    :agent_status,
    :claimed_until,
    :review_requested_at,
    :implementer_dispatch_id
  ]

  @type thread :: %{
          checkpoints: [Checkpoint.t()],
          checkpoints_truncated: boolean(),
          entries: [Entry.t()],
          next_after_seq: pos_integer() | nil
        }

  @doc """
  The story's thread: its most recent checkpoints (at most #{@max_entry_page}), and one page of
  its entries, each in `seq` order. `:after_seq` starts the page after that entry; `:limit` is capped at
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

  @doc false
  # The advisory-lock namespace every write takes, for a test that holds the lock itself.
  @spec lock_namespace() :: integer()
  def lock_namespace, do: @thread_lock_namespace

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
  - `:author_principal` (required), `:actor_lineage` (required) — SERVER-resolved: a lineage
    list, or `:custody` for the lineage of the dispatch the story's claim recorded
    (`implementer_dispatch_id`), read under the story's lock
  - `:replay_only` — answer only the recorder's resend of a checkpoint already recorded, and
    refuse anything else `:dispatch_not_accepted`. For a runner whose dispatch is no longer
    accepted (`Loopctl.Delivery.RunnerThreads`): it may be told its earlier write landed, and
    may write nothing new.

  Returns `{:ok, checkpoint, :created | :existing}`.
  """
  @spec record_checkpoint(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, Checkpoint.t(), :created | :existing}
          | {:error, term()}
          | {:error, :unprocessable_entity, String.t() | map()}
  def record_checkpoint(tenant_id, story_id, opts) do
    commit_sha = Keyword.fetch!(opts, :commit_sha)
    tree_sha = Keyword.fetch!(opts, :tree_sha)
    note = Keyword.get(opts, :note)

    with :ok <- valid_sha(commit_sha, "commit_sha"),
         :ok <- valid_sha(tree_sha, "tree_sha"),
         :ok <- same_object_format(commit_sha, tree_sha),
         :ok <- valid_note(note),
         :ok <- no_secret(note, :note, tenant_id, story_id) do
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

  - `:author_principal` (required), `:actor_lineage` (required) — as for
    `record_checkpoint/3`
  - `:claim_epoch` — when given, the story's `claim_epoch` must still be this one, read under
    the story's lock, or a NEW write is `{:error, :stale_claim_epoch}`. A runner's note is
    lineage-attributed to the claim it ran under, and that claim's lineage is only its own
    while its epoch is current.
  - `:replay_only` — answer only a resend of an entry already recorded, and refuse a new one
    `:dispatch_not_accepted`, as for a checkpoint.

  A resend of an entry already recorded by this author under this key is answered from the
  row BEFORE either check: it writes nothing, so no claim needs to be current for it, and a
  runner that lost the ack must be able to learn its note landed.

  Returns `{:ok, entry, :created | :existing}`.
  """
  @spec record_entry(Ecto.UUID.t(), Ecto.UUID.t(), map(), keyword()) ::
          {:ok, Entry.t(), :created | :existing}
          | {:error, term()}
          | {:error, :unprocessable_entity, String.t() | map()}
  def record_entry(tenant_id, story_id, attrs, opts) do
    changeset = Entry.changeset(%Entry{}, attrs)

    with :ok <- caller_kind(changeset),
         :ok <- screen(changeset, tenant_id, story_id) do
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

      {checkpoints, truncated?} = latest_checkpoints(tenant_id, story_id)

      {:ok,
       %{
         checkpoints: checkpoints,
         checkpoints_truncated: truncated?,
         entries: page,
         next_after_seq: if(rest == [], do: nil, else: List.last(page).seq)
       }}
    else
      {:error, :not_found}
    end
  end

  # The most recent checkpoints, oldest first. A thread that recorded more than a page's worth
  # returns only the latest page: the merge gate and a reviewer need the current head and
  # what led to it, never the whole history on every poll.
  defp latest_checkpoints(tenant_id, story_id) do
    rows =
      Checkpoint
      |> where([c], c.tenant_id == ^tenant_id and c.story_id == ^story_id)
      |> order_by([c], desc: c.seq)
      |> limit(^(@max_entry_page + 1))
      |> Repo.all()

    {page, rest} = Enum.split(rows, @max_entry_page)
    {Enum.reverse(page), rest != []}
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

  @doc false
  # The story row, FOR SHARE, inside a `write_locked/3` transaction.
  @spec locked_story(Ecto.UUID.t(), Ecto.UUID.t()) :: Story.t() | nil
  def locked_story(tenant_id, story_id),
    do: Repo.one(story_query(tenant_id, story_id) |> lock("FOR SHARE"))

  # ---------------------------------------------------------------------------
  # Checkpoints
  # ---------------------------------------------------------------------------

  # A resend from the principal that recorded the checkpoint is answered from the row BEFORE
  # the fence: the write already happened under a claim that was live, and a lost response
  # followed by a lapsed lease must not read as "never recorded". It writes nothing. Anyone
  # else, and every new write, goes through the fence.
  defp checkpoint_locked(tenant_id, story_id, commit_sha, tree_sha, opts) do
    epoch = Keyword.fetch!(opts, :claim_epoch)

    case {locked_story(tenant_id, story_id),
          checkpoint_by_sha(tenant_id, story_id, commit_sha, epoch)} do
      {nil, _} ->
        {:error, :not_found}

      {story, nil} ->
        with :ok <- fence(story, opts, epoch),
             do:
               insert_checkpoint(
                 tenant_id,
                 story_id,
                 commit_sha,
                 tree_sha,
                 with_lineage(opts, tenant_id, story)
               )

      {story, existing} ->
        fence = fn -> fence(story, opts, epoch) end
        recorded = checkpoint_entry(existing)

        with :ok <- replay_allowed(recorded, Keyword.fetch!(opts, :author_principal), fence),
             do: replay_checkpoint(existing, recorded, tree_sha, Keyword.get(opts, :note))
    end
  end

  # Only the recorder replays. Anyone else meets the fence, which is there to NAME the refusal
  # (an ended claim, a stranger): a checkpoint under epoch E was recorded by E's claimant, so
  # nobody but its recorder can pass it.
  defp replay_allowed(%{author_principal: author}, author, _fence), do: :ok
  defp replay_allowed(_recorded, _author, fence), do: fence.()

  # The checkpoint's own entry, read once: who recorded it and the note it carries.
  defp checkpoint_entry(checkpoint) do
    Repo.one(
      from e in Entry,
        where: e.checkpoint_id == ^checkpoint.id and e.kind == :checkpoint,
        select: %{author_principal: e.author_principal, body: e.body}
    )
  end

  # Decided on the story row this transaction already holds FOR SHARE.
  defp fence(story, opts, epoch) do
    if Keyword.get(opts, :replay_only, false),
      do: {:error, :dispatch_not_accepted},
      else: claimant_fence(story, Keyword.fetch!(opts, :agent_id), epoch)
  end

  @doc false
  # The checkpoint fence, for a `fix` (`Loopctl.Threads.Reviews`): the current claimant under
  # the current epoch with a live lease, decided on a story row held FOR SHARE.
  @spec claimant_fence(Story.t(), Ecto.UUID.t() | nil, term()) ::
          :ok | {:error, :not_claimant | :stale_claim_epoch | :claim_not_live}
  def claimant_fence(story, agent_id, epoch) do
    with :ok <- Claimant.check(story, agent_id, epoch), do: lease(story)
  end

  # `:custody` is resolved HERE, on the row held FOR SHARE, so the lineage is the one the
  # claim the write is fenced on recorded: a claim or release cannot change
  # `implementer_dispatch_id` between this read and the insert. It is a foreign key with no
  # delete, so a declared dispatch always resolves; a claim no placement made has none, `[]`.
  defp with_lineage(opts, tenant_id, story) do
    case Keyword.fetch!(opts, :actor_lineage) do
      :custody -> Keyword.put(opts, :actor_lineage, custody_lineage(tenant_id, story))
      lineage when is_list(lineage) -> opts
    end
  end

  defp custody_lineage(_tenant_id, %Story{implementer_dispatch_id: nil}), do: []

  defp custody_lineage(tenant_id, %Story{implementer_dispatch_id: dispatch_id}) do
    Repo.one(
      from d in Dispatch,
        where: d.id == ^dispatch_id and d.tenant_id == ^tenant_id,
        select: d.lineage_path
    ) || []
  end

  defp lease(story) do
    if Claimant.live?(story, DateTime.utc_now()),
      do: :ok,
      else: {:error, :claim_not_live}
  end

  # The same checkpoint, resent: the tree must match, and a note, when sent, must be the one
  # recorded. Anything else is a different write, refused rather than acknowledged.
  defp replay_checkpoint(%Checkpoint{tree_sha: tree_sha} = existing, recorded, tree_sha, note) do
    if is_nil(note) or note == recorded.body,
      do: {:ok, existing, :existing, []},
      else: conflict("checkpoint_conflict", "commit_sha is already recorded with another note")
  end

  defp replay_checkpoint(_existing, _recorded, _tree_sha, _note),
    do: conflict("checkpoint_conflict", "commit_sha is already recorded with another tree_sha")

  defp insert_checkpoint(tenant_id, story_id, commit_sha, tree_sha, opts) do
    lineage = Keyword.fetch!(opts, :actor_lineage)
    epoch = Keyword.fetch!(opts, :claim_epoch)
    previous = latest_checkpoint(tenant_id, story_id)
    # The parent is the previous checkpoint OF THIS CLAIM, the one this claimant built on. A
    # claim resuming at an earlier commit than the last one recorded would otherwise get a
    # parent that git says is its descendant; a claim's first checkpoint has none.
    parent = latest_checkpoint(tenant_id, story_id, epoch)

    checkpoint =
      Repo.insert!(%Checkpoint{
        tenant_id: tenant_id,
        story_id: story_id,
        seq: if(previous, do: previous.seq + 1, else: 1),
        commit_sha: commit_sha,
        tree_sha: tree_sha,
        parent_checkpoint_id: parent && parent.id,
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

    adopted = %{
      "commit_sha" => commit_sha,
      "tree_sha" => tree_sha,
      "claim_epoch" => epoch,
      "checkpoint_seq" => checkpoint.seq
    }

    with {:ok, _entry, :created, chained} <-
           insert_entry(tenant_id, story_id, entry, Keyword.put(opts, :adopted, adopted)) do
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

  defp latest_checkpoint(tenant_id, story_id, epoch \\ :any) do
    query =
      from c in Checkpoint,
        where: c.tenant_id == ^tenant_id and c.story_id == ^story_id,
        order_by: [desc: c.seq],
        limit: 1

    query = if epoch == :any, do: query, else: where(query, [c], c.claim_epoch == ^epoch)
    Repo.one(query)
  end

  # One repository uses one object format: a SHA-1 commit has a SHA-1 tree.
  defp same_object_format(commit_sha, tree_sha) do
    if byte_size(commit_sha) == byte_size(tree_sha),
      do: :ok,
      else:
        {:error, :unprocessable_entity,
         "commit_sha and tree_sha must be the same object format (both 40 or both 64)"}
  end

  defp valid_sha(value, field) do
    if is_binary(value) and Regex.match?(@sha_pattern, value),
      do: :ok,
      else: {:error, :unprocessable_entity, "#{field} must be 40 or 64 lowercase hex characters"}
  end

  defp valid_note(nil), do: :ok

  # Whitespace-only is empty, as the changeset's cast treats an entry body.
  defp valid_note(note) when is_binary(note) do
    cond do
      String.trim(note) == "" ->
        {:error, :unprocessable_entity, "note must be a non-empty string"}

      byte_size(note) > Entry.max_body_bytes() ->
        {:error, :unprocessable_entity, "note must be at most #{Entry.max_body_bytes()} bytes"}

      true ->
        :ok
    end
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
         "kind #{kind} is written by the review flow (the thread's #{kind} endpoint), " <>
           "not as an entry"}

      kind == :review_requested ->
        {:error, :unprocessable_entity,
         "kind review_requested is written by the request-review flow, not a caller"}

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

  @doc false
  # The screen every caller-written entry passes before its transaction opens: the reserved
  # key prefix, and the secret scan of its body and key.
  @spec screen(Ecto.Changeset.t(), Ecto.UUID.t(), Ecto.UUID.t()) ::
          :ok | {:error, :unprocessable_entity, String.t() | map()}
  def screen(changeset, tenant_id, story_id) do
    with :ok <- reserved_key(changeset),
         :ok <-
           no_secret(Ecto.Changeset.get_field(changeset, :body), :body, tenant_id, story_id) do
      no_secret(
        Ecto.Changeset.get_field(changeset, :idempotency_key),
        :idempotency_key,
        tenant_id,
        story_id
      )
    end
  end

  defp no_secret(value, field, tenant_id, story_id) do
    if SecretDenylist.contains_secret?(value) do
      # The same signal the coordination bus emits, so thread leak attempts reach the same
      # dashboards and alerts. The value itself is never logged.
      :telemetry.execute([:loopctl, :threads, :secret_blocked], %{count: 1}, %{
        tenant_id: tenant_id,
        story_id: story_id,
        field: field
      })

      Logger.warning(
        "thread denylist hit: blocked #{field} carrying a credential shape " <>
          "(tenant=#{tenant_id} story=#{story_id})"
      )

      {:error, :unprocessable_entity,
       %{
         code: "secret_blocked",
         message: "#{field} carries a credential-shaped value and was not recorded"
       }}
    else
      :ok
    end
  end

  defp entry_locked(tenant_id, story_id, changeset, opts) do
    author = Keyword.fetch!(opts, :author_principal)
    key = Ecto.Changeset.get_field(changeset, :idempotency_key)

    with {:story, %Story{} = story} <- {:story, locked_story(tenant_id, story_id)},
         nil <- entry_by_key(tenant_id, story_id, author, key),
         :ok <- new_write_allowed(opts),
         :ok <- epoch_current(story, Keyword.get(opts, :claim_epoch)),
         :ok <- checkpoint_of_story(changeset, tenant_id, story_id) do
      insert_entry(tenant_id, story_id, changeset, with_lineage(opts, tenant_id, story))
    else
      {:story, nil} -> {:error, :not_found}
      %Entry{} = existing -> replay(existing, changeset)
      error -> error
    end
  end

  defp new_write_allowed(opts) do
    if Keyword.get(opts, :replay_only, false),
      do: {:error, :dispatch_not_accepted},
      else: :ok
  end

  defp epoch_current(_story, nil), do: :ok
  defp epoch_current(%Story{claim_epoch: epoch}, epoch), do: :ok
  defp epoch_current(_story, _epoch), do: {:error, :stale_claim_epoch}

  @doc false
  # `nil` when `author` has written nothing under the changeset's key; otherwise the answer to
  # a resend — the row when it is the SAME write, `idempotency_key_reused` when it is not.
  @spec replayed(Ecto.UUID.t(), Ecto.UUID.t(), String.t(), Ecto.Changeset.t()) ::
          nil | {:ok, Entry.t(), :existing, []} | {:error, {:conflict, String.t(), String.t()}}
  def replayed(tenant_id, story_id, author, changeset) do
    key = Ecto.Changeset.get_field(changeset, :idempotency_key)

    case entry_by_key(tenant_id, story_id, author, key) do
      nil -> nil
      existing -> replay(existing, changeset)
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
  @replayed_fields [
    :kind,
    :body,
    :checkpoint_id,
    :review_id,
    :severity,
    :location,
    :introduced_by,
    :finding_ids
  ]

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

  @doc false
  # Inserts `changeset` as the thread's next entry and appends it to the audit chain, inside a
  # `write_locked/3` transaction. `opts` carries `:author_principal` and a resolved
  # `:actor_lineage` list.
  @spec insert_entry(Ecto.UUID.t(), Ecto.UUID.t(), Ecto.Changeset.t(), keyword()) ::
          {:ok, Entry.t(), :created, list()} | {:error, term()}
  def insert_entry(tenant_id, story_id, changeset, opts) do
    lineage = Keyword.fetch!(opts, :actor_lineage)

    changeset =
      changeset
      |> Ecto.Changeset.put_change(:tenant_id, tenant_id)
      |> Ecto.Changeset.put_change(:story_id, story_id)
      |> Ecto.Changeset.put_change(:seq, next_entry_seq(tenant_id, story_id))
      |> Ecto.Changeset.put_change(:author_principal, Keyword.fetch!(opts, :author_principal))
      |> Ecto.Changeset.put_change(:dispatch_id, List.last(lineage))

    with {:ok, entry} <- Repo.insert(changeset),
         {:ok, chain_entry} <-
           chain(tenant_id, story_id, entry, lineage, Keyword.get(opts, :adopted, %{})) do
      {:ok, entry, :created, [chain_entry]}
    end
  end

  # A checkpoint's event pins WHICH commit was adopted, under which claim, so the chain can
  # show the merge gate's record is the commit the claimant reported.
  defp chain(tenant_id, story_id, entry, lineage, adopted) do
    AuditChain.append_in_tenant_transaction(tenant_id, %{
      action: "thread_#{entry.kind}_recorded",
      actor_lineage: lineage,
      entity_type: "story",
      entity_id: story_id,
      payload:
        Map.merge(
          %{
            "thread_entry_id" => entry.id,
            "seq" => entry.seq,
            "kind" => to_string(entry.kind),
            "author_principal" => entry.author_principal,
            "checkpoint_id" => entry.checkpoint_id
          },
          Map.merge(judgement(entry), adopted)
        )
    })
  end

  # A judgement's event pins what the round count and the ceiling are computed from: which
  # review wrote it, its severity and origin, and the findings a fix answers. A message or a
  # checkpoint carries none of these, and its event carries none of the keys.
  defp judgement(entry) do
    %{
      "review_id" => entry.review_id,
      "severity" => entry.severity && to_string(entry.severity),
      "introduced_by" => entry.introduced_by,
      "finding_ids" => entry.finding_ids
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp conflict(code, message), do: {:error, {:conflict, code, message}}

  # ---------------------------------------------------------------------------
  # Transaction and ordering
  # ---------------------------------------------------------------------------

  # `fun` answers `{:ok, value, status, chain_entries}`; the chain entries are announced only
  # once the transaction that wrote them has committed.
  #
  # EVERY lock the write waits for — the per-story lock, the story's FOR SHARE, and the
  # tenant's audit-chain lock the append takes — is bounded by `Capacity.lock_timeout_ms/0`,
  # the wait `Capacity.busy_retry_ms/0` (every `:busy` refusal's retry interval) is derived
  # from, so the retry a caller is told is always longer than the wait that just ran out.
  # Contention — a lock wait that ran out, a deadlock Postgres broke by choosing this write, a
  # connection lost — is `{:error, :busy}` through `Stages.answering_busy/4`, the one copy of
  # that policy, counted as `[:loopctl, :threads, :busy]`. Unanswered, each raised inside the
  # runner channel's `handle_in` and took down every session on that socket; over HTTP it was
  # a 500. `:busy` does not promise nothing was written — a connection lost while the write
  # committed may have committed it — and both writes are safe to resend: the resend of one
  # that landed is answered from its row. A chain HASH violation is not contention and still
  # raises, for the caller to answer.
  @doc false
  # The one write transaction, for `Loopctl.Threads.Reviews`: `fun` runs under the per-story
  # lock and answers `{:ok, value, status, chain_entries}` or an error that rolls it back.
  @spec write_locked(Ecto.UUID.t(), Ecto.UUID.t(), (-> term())) :: {:ok, term(), atom()} | term()
  def write_locked(tenant_id, story_id, fun), do: in_story_lock(tenant_id, story_id, fun)

  defp in_story_lock(tenant_id, story_id, fun) do
    Stages.answering_busy(tenant_id, [:loopctl, :threads, :busy], "thread write", fn ->
      tenant_id
      |> Repo.with_tenant(fn ->
        Capacity.set_lock_timeout!()

        Repo.query!("SELECT pg_advisory_xact_lock($1::int, hashtext($2))", [
          @thread_lock_namespace,
          story_id
        ])

        committed_or_rolled_back(fun.())
      end)
      |> announced()
    end)
  end

  defp committed_or_rolled_back({:ok, _, _, _} = ok), do: ok
  defp committed_or_rolled_back(error), do: Repo.rollback(error)

  defp announced({:ok, {:ok, value, status, chained}}) do
    Enum.each(chained, &AuditChain.announce_entry/1)
    {:ok, value, status}
  end

  defp announced({:error, error}), do: error

  defp next_entry_seq(tenant_id, story_id) do
    Repo.one(
      from e in Entry,
        where: e.tenant_id == ^tenant_id and e.story_id == ^story_id,
        select: coalesce(max(e.seq), 0)
    ) + 1
  end
end
