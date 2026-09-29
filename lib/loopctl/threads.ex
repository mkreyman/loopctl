defmodule Loopctl.Threads do
  @moduledoc """
  A story's change thread (US-45.1, Epic 45 PRD §3): the checkpoints its claimant reported and
  the entries written around them. A thread is a story, 1:1, and outlives any one dispatch.

  ## What this module owns, and what it deliberately does not

  It owns the RECORD and every write to it: checkpoints, `message` entries, and the review
  kinds (US-45.3). Findings, verdicts and the fixes that answer them decide what may merge, so
  each has ONE narrow entry point here that binds its author under the thread lock:

  - `record_review/3` — loopctl placing a review as a runner dispatch of kind `review`;
  - `record_judgement/5` — a `finding` or `verdict` from the runner holding that dispatch,
    bound to its `thread_reviews` row. Inferring a judge from a calling key was circumvented
    in #901 and #905; nothing here takes a key;
  - `record_fix/4` — a `fix` from the story's current claimant, under the checkpoint fence;
  - `record_human_finding/3` — a `finding` from the tenant's human on the thread page
    (US-45.7), as `human_principal/0` with an empty lineage. It has no HTTP route: the only
    principal that writes it is the WebAuthn-authenticated browser session.

  Two writes are loopctl's own and have NO HTTP route, because the merge executor
  (`Loopctl.Delivery.MergeExecutor`, US-45.5) is their only caller:
  `record_base_update/4` — the base merged into the thread, which bypasses the claimant fence
  because loopctl, not the claimant, made the commit — and `record_merge_commit/6`.

  The rules each applies are `Loopctl.Threads.Reviews`', which only reads. The insert, the
  lock and the replay stay private to this module, so there is no other way in.

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
  alias Loopctl.Delivery.DispatchPayload
  alias Loopctl.Delivery.PullRequestSource
  alias Loopctl.Delivery.Stages
  alias Loopctl.Dispatches.Dispatch
  alias Loopctl.GitSha
  alias Loopctl.Intake
  alias Loopctl.Repo
  alias Loopctl.Runners
  alias Loopctl.Runners.Capacity
  alias Loopctl.Runners.DispatchRecord
  alias Loopctl.Security.SecretDenylist
  alias Loopctl.Threads.Checkpoint
  alias Loopctl.Threads.Entry
  alias Loopctl.Threads.IssueLinks
  alias Loopctl.Threads.Review
  alias Loopctl.Threads.Reviews
  alias Loopctl.Verification.Credential
  alias Loopctl.WorkBreakdown.Story

  @thread_lock_namespace :erlang.phash2(:loopctl_thread_ledger)

  # The author of a `base_update` checkpoint's entry: loopctl's merge executor (US-45.5).
  @merge_executor_principal "control:merge_executor"
  # The tenant's human, authenticated in the browser by the WebAuthn credential enrolled at
  # signup (US-45.7). The label the audit chain already gives WebAuthn-authenticated human acts
  # (`Loopctl.Tenants`, `Loopctl.Tenants.Enrollment`). No API key can produce it:
  # `LoopctlWeb.ActorLabel` gives `agent:` or `api_key:`. The `thread_entries_judgement_shape`
  # CHECK names it literally, as the one author a finding with no review may have.
  @human_principal "human:webauthn"

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

  @typedoc """
  What the merge gate judges for a THREAD-mode story (US-45.4), read in one tenant
  transaction:

  - `:latest` — the JUDGED HEAD: the latest checkpoint the story's CURRENT claim recorded (its
    `claim_epoch` now) that the gate may judge, or `nil` when that claim recorded none. That
    is every checkpoint of kind `checkpoint`, plus a `base_update` whose chain of parents
    reaches the checkpoint the gate LAST allowed (`Loopctl.Delivery.Stages.last_allow_query/2`,
    AC-45.5.9): the executor merged the base into the allowed work, so the same change comes
    back through the gate on a newer base. Any other `base_update` is invisible here. loopctl
    never adopts a branch head nobody reported, and a checkpoint an ENDED claim recorded is
    that claim's work, not the current one's
  - `:earlier_shas` — the current claim's OTHER judged checkpoints' commits, newest first. A
    branch naming one of them has gone back, not forward
  - `:earlier_claim_recorded?` — whether any ENDED claim recorded a checkpoint. With no
    `:latest`, it tells a thread whose claim was released (the gate's `claim_ended`) from one
    that never recorded anything (`no_checkpoint_recorded`)
  """
  @type claim_checkpoints :: %{
          latest: Checkpoint.t() | nil,
          earlier_shas: [String.t()],
          earlier_claim_recorded?: boolean()
        }

  @doc """
  The current claim's checkpoints as `t:claim_checkpoints/0`, or `{:error, reason}` when they
  could not be read — `{:error, :busy}` for contention a caller retries out of
  (`Loopctl.Delivery.Stages.answering_busy/4`, the one classification of that), or
  `{:error, :not_found}` for a story not in the tenant. Never raises for either. Takes no lock.
  """
  @spec claim_checkpoints(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, claim_checkpoints()} | {:error, term()}
  def claim_checkpoints(tenant_id, story_id) do
    Stages.answering_busy(tenant_id, [:loopctl, :threads, :busy], "thread read", fn ->
      tenant_id
      |> Repo.with_tenant(fn -> read_claim_checkpoints(tenant_id, story_id) end)
      |> unwrap_read()
    end)
  end

  defp unwrap_read({:ok, {:ok, result}}), do: {:ok, result}
  defp unwrap_read({:ok, {:error, _reason} = error}), do: error
  defp unwrap_read({:error, _reason} = error), do: error

  # ONE query: the story's current epoch and every checkpoint's few judged fields — never
  # `gate_evidence` — split by claim here, and the gate's last allow, which decides which
  # `base_update` checkpoints are judged. A story not in the tenant is no row at all.
  defp read_claim_checkpoints(tenant_id, story_id) do
    rows =
      Repo.all(
        from s in Story,
          left_join: c in Checkpoint,
          on: c.tenant_id == s.tenant_id and c.story_id == s.id,
          where: s.id == ^story_id and s.tenant_id == ^tenant_id,
          order_by: [desc: c.seq],
          select:
            {s.claim_epoch,
             %{
               id: c.id,
               seq: c.seq,
               commit_sha: c.commit_sha,
               tree_sha: c.tree_sha,
               claim_epoch: c.claim_epoch,
               merge_commit_sha: c.merge_commit_sha,
               kind: c.kind,
               parent_checkpoint_id: c.parent_checkpoint_id,
               # The merge gate's CI-wait fallback origin (US-45.6).
               inserted_at: c.inserted_at
             }}
      )

    case rows do
      [] ->
        {:error, :not_found}

      [{epoch, _} | _] ->
        allowed = Repo.one(Stages.last_allow_query(tenant_id, story_id))
        {:ok, split_by_claim(epoch, Enum.map(rows, &elem(&1, 1)), allowed)}
    end
  end

  defp split_by_claim(epoch, checkpoints, allowed) do
    # A story with no checkpoint joins to one row of NULLs.
    checkpoints = Enum.reject(checkpoints, &is_nil(&1.id))
    judged = judged_checkpoints(checkpoints, allowed)
    {current, earlier_claims} = Enum.split_with(judged, &(&1.claim_epoch == epoch))

    {latest, earlier} =
      case current do
        [latest | earlier] -> {struct(Checkpoint, latest), earlier}
        [] -> {nil, []}
      end

    %{
      latest: latest,
      earlier_shas: Enum.map(earlier, & &1.commit_sha),
      earlier_claim_recorded?: earlier_claims != []
    }
  end

  # AC-45.5.9: every claimant checkpoint, and a `base_update` only when it IS the checkpoint
  # the gate last allowed or its parents lead back to it. The first half is what lets the
  # executor merge a base update once the gate has allowed it: from then on the allow names
  # the base update itself. The walk follows `parent_checkpoint_id` through the story's own
  # rows, so it is bounded by them and cannot cycle: each id is visited once.
  defp judged_checkpoints(checkpoints, allowed) do
    by_id = Map.new(checkpoints, &{&1.id, &1})
    allowed_id = allowed && allowed.checkpoint_id

    Enum.filter(checkpoints, fn
      %{kind: :base_update, id: ^allowed_id} -> true
      %{kind: :base_update} = checkpoint -> reaches?(checkpoint, allowed_id, by_id, MapSet.new())
      _claimant -> true
    end)
  end

  defp reaches?(_checkpoint, nil, _by_id, _seen), do: false

  defp reaches?(%{parent_checkpoint_id: nil}, _allowed_id, _by_id, _seen), do: false

  defp reaches?(%{parent_checkpoint_id: allowed_id}, allowed_id, _by_id, _seen), do: true

  defp reaches?(%{parent_checkpoint_id: parent_id}, allowed_id, by_id, seen) do
    case {Map.fetch(by_id, parent_id), MapSet.member?(seen, parent_id)} do
      {{:ok, parent}, false} -> reaches?(parent, allowed_id, by_id, MapSet.put(seen, parent_id))
      _unknown_or_seen -> false
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

  @doc """
  Records a review of `story_id` placed as the runner dispatch `:dispatch_id` (US-45.3), for
  the next round, on the story's latest checkpoint of the current claim. Called by
  `Loopctl.Delivery.Placement.place_review/4` BEFORE the dispatch is pushed, so a refused push
  leaves an inert row and never a session with nothing to bind its judgements to.

  Under the thread lock it re-decides everything the placement read: that a dispatch made the
  claim, the checkpoint, the round and the reviewer's separation (`Loopctl.Threads.Reviews`).

  ## Options

  - `:dispatch_id`, `:runner_id`, `:agent_id` (required) — the ledger dispatch id the review
    will be pushed under, the runner, and the runner's agent (the reviewer).
  - `:placed_by` (required) — the requesting principal's label, for the record.

  IDEMPOTENT on `:dispatch_id`: the same placement again answers the row
  (`:existing`); the id under another story or runner is `dispatch_id_conflict`.
  """
  @spec record_review(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, Review.t(), :created | :existing} | {:error, term()}
  def record_review(tenant_id, story_id, opts) do
    in_story_lock(tenant_id, story_id, fn -> review_locked(tenant_id, story_id, opts) end)
  end

  @doc """
  Records a `finding` or `verdict` from the review dispatch `dispatch_id`, which `runner_id`
  holds (US-45.3). The ONE way a REVIEWER's judgement is written (a human's finding is
  `record_human_finding/3`): the review is bound under the thread
  lock by the dispatch AND the runner, then its separation, whether it is still open and
  whether its round is still current are decided there too.

  `attrs` (string keys): `kind` (`finding` | `verdict`), `idempotency_key`, `body`, and for a
  finding `severity`, an optional `location` and `introduced_by`. The key is scoped to the
  review. A NEW judgement is refused `:tenant_halted` while the tenant's custody is halted; a
  resend of one already recorded is answered from its row even then.

  ## Options

  - `:runner_id` (required) — the runner the socket authenticated.
  - `:author_principal` (required) — the runner's agent label.
  - `:replay_only` — answer only a resend of a judgement already recorded.

  Returns `{:ok, %{entry: entry, escalation: entry | nil}, :created | :existing}`.
  """
  @spec record_judgement(Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t(), map(), keyword()) ::
          {:ok, %{entry: Entry.t(), escalation: Entry.t() | nil}, :created | :existing}
          | {:error, term()}
          | {:error, :unprocessable_entity, term()}
  def record_judgement(tenant_id, story_id, dispatch_id, attrs, opts) do
    with {:ok, changeset} <- judgement_changeset(attrs),
         :ok <- screen(changeset, tenant_id, story_id),
         :ok <-
           no_secret(
             Ecto.Changeset.get_field(changeset, :location),
             :location,
             tenant_id,
             story_id
           ) do
      in_story_lock(tenant_id, story_id, fn ->
        judgement_locked(tenant_id, story_id, dispatch_id, changeset, opts)
      end)
    end
  end

  @doc """
  The review loopctl recorded for `dispatch_id` in this tenant, or nil (US-45.3). A read for
  `Loopctl.Delivery.Placement.place_review/4`, which answers a retry of a recorded placement
  from its row.
  """
  @spec review_by_dispatch(Ecto.UUID.t(), Ecto.UUID.t()) :: Review.t() | nil
  def review_by_dispatch(tenant_id, dispatch_id) do
    {:ok, review} =
      Repo.with_tenant(tenant_id, fn ->
        Repo.one(
          from r in Review, where: r.tenant_id == ^tenant_id and r.dispatch_id == ^dispatch_id
        )
      end)

    review
  end

  @doc """
  Records a `fix` from the story's current claimant (US-45.3): the checkpoint that carries it
  and the findings of completed rounds it answers. The checkpoint fence applies — the claimant
  under the current epoch with a live lease — and the checkpoint must be one this claim
  recorded after every checkpoint its findings were found in. Refused `:tenant_halted` while
  the tenant's custody is halted.

  `attrs` (string keys): `checkpoint_id`, `finding_ids`, `idempotency_key`, `body`.

  ## Options

  - `:agent_id`, `:claim_epoch`, `:author_principal`, `:actor_lineage` (required) —
    server-resolved from the calling key.
  """
  @spec record_fix(Ecto.UUID.t(), Ecto.UUID.t(), map(), keyword()) ::
          {:ok, Entry.t(), :created | :existing}
          | {:error, term()}
          | {:error, :unprocessable_entity, term()}
  def record_fix(tenant_id, story_id, attrs, opts) do
    changeset =
      Entry.changeset(%Entry{}, %{
        "kind" => "fix",
        "idempotency_key" => Map.get(attrs, "idempotency_key"),
        "body" => Map.get(attrs, "body"),
        "checkpoint_id" => Map.get(attrs, "checkpoint_id")
      })

    with :ok <- not_halted(tenant_id),
         :ok <- valid(changeset),
         :ok <- fix_checkpoint_given(changeset),
         {:ok, finding_ids} <- Reviews.finding_ids(Map.get(attrs, "finding_ids")),
         :ok <- screen(changeset, tenant_id, story_id) do
      changeset = Ecto.Changeset.change(changeset, finding_ids: finding_ids)

      in_story_lock(tenant_id, story_id, fn ->
        fix_locked(tenant_id, story_id, changeset, opts)
      end)
    end
  end

  @doc """
  The principal the tenant's human writes as from the thread page (US-45.7): authenticated in
  the browser by the WebAuthn credential enrolled at signup, with an EMPTY lineage. The label
  WebAuthn-authenticated human acts already carry in the audit chain; no API key produces it.
  """
  @spec human_principal() :: String.t()
  def human_principal, do: @human_principal

  @doc """
  Records a `finding` from the tenant's human (US-45.7, PRD §6: "a human finding has the same
  standing as an agent's: it binds to a checkpoint and counts toward `introduced_by` and the
  ceiling"). Written by the thread page only; there is no HTTP route, because the only
  principal that may write it is the WebAuthn-authenticated browser session.

  `attrs` (string keys): `idempotency_key` (the page's per-form nonce), `body`,
  `checkpoint_id`, `severity`, and optionally `location` and `introduced_by`.

  The finding binds to a checkpoint of kind `checkpoint` that the story's CURRENT, still-held
  claim recorded: rounds belong to a claim, and a finding on an ended claim's work could count
  for the one that follows. `introduced_by` follows the round rule a reviewer's does
  (`Loopctl.Threads.Reviews.human_introduced_by_allowed/4`). It counts in the round in progress
  when it was written (`Loopctl.Threads.Reviews`).

  A MATERIAL finding written once the claim's rounds have reached the ceiling has no round left
  to count in, so it escalates the story over the same `review_ceiling` edge a ceiling verdict
  does: the escalation entry is recorded in this transaction, bound to the final review, and
  `Loopctl.Workers.ReviewCeilingWorker` moves the stage. One escalation per review: when the
  ceiling verdict already escalated, that one is returned, marked as already there.

  Refused `:tenant_halted` while the tenant's custody is halted, as every judgement is. A
  resend of a finding already recorded under the same key is answered from its row — halt
  included — so a double submit is one entry; a different finding reusing the key is
  `idempotency_key_reused`.

  `escalation` says which of the two happened: `{:escalated, entry}` when THIS finding recorded
  the escalation, `{:already_escalated, entry}` when the story was already escalated at the
  ceiling (by the ceiling verdict or an earlier finding) and this one changed nothing. A resend
  answers what its first delivery RECORDED: `{:escalated, entry}` when that delivery wrote the
  escalation, nil otherwise — an `:already_escalated` first answer recorded nothing — and never
  anything inferred from the ceiling as it stands at the resend.

  Returns `{:ok, %{entry: entry, escalation: nil | {:escalated | :already_escalated, entry}},
  :created | :existing}`.
  """
  @spec record_human_finding(Ecto.UUID.t(), Ecto.UUID.t(), map()) ::
          {:ok,
           %{
             entry: Entry.t(),
             escalation: nil | {:escalated | :already_escalated, Entry.t()}
           }, :created | :existing}
          | {:error, term()}
          | {:error, :unprocessable_entity, term()}
  def record_human_finding(tenant_id, story_id, attrs) do
    changeset =
      Entry.changeset(%Entry{}, %{
        "kind" => "finding",
        "idempotency_key" => Map.get(attrs, "idempotency_key"),
        "body" => Map.get(attrs, "body"),
        "checkpoint_id" => Map.get(attrs, "checkpoint_id")
      })

    with :ok <- valid(changeset),
         :ok <- human_finding_checkpoint_given(changeset),
         {:ok, changeset} <- finding_fields(changeset, attrs),
         :ok <- screen(changeset, tenant_id, story_id),
         :ok <-
           no_secret(
             Ecto.Changeset.get_field(changeset, :location),
             :location,
             tenant_id,
             story_id
           ) do
      in_story_lock(tenant_id, story_id, fn ->
        human_finding_locked(tenant_id, story_id, changeset)
      end)
    end
  end

  @typedoc """
  The checkpoints the thread page shows, and the claim a human finding may bind to: its epoch,
  whether it is still held, and its own claimant checkpoints (`Reviews.human_finding_checkpoint/3`
  accepts nothing else).
  """
  @type page_checkpoints :: %{
          checkpoints: [Checkpoint.t()],
          checkpoints_truncated: boolean(),
          claim_checkpoints: [Checkpoint.t()]
        }

  @typedoc "What the thread page renders (US-45.7)."
  @type page :: %{
          story: %{id: Ecto.UUID.t(), number: String.t() | nil, title: String.t()},
          checkpoints: [Checkpoint.t()],
          checkpoints_truncated: boolean(),
          claim_checkpoints: [Checkpoint.t()],
          entries: [Entry.t()],
          older_before_seq: pos_integer() | nil,
          findings: [Entry.t()],
          repo: String.t() | nil,
          halted: boolean()
        }

  @doc """
  The thread page's read (US-45.7), with no forge call. One `Loopctl.Repo.with_tenant/2`
  transaction under the tenant's RLS reads:

  - `entries`, `older_before_seq` — the NEWEST page of entries (`page_entries/3`);
  - `checkpoints`, `checkpoints_truncated`, `claim_checkpoints` — `page_checkpoints/2`;
  - `findings` — the story's findings, the latest #{@max_entry_page}, oldest first, whatever
    page of entries is loaded;
  - `repo` — the repository diffs come from, or nil when the project has no single live intake
    source.

  `halted` — whether the tenant's custody is halted — is the thread's one halt check
  (`Runners.custody_halted?/1`), asked after that transaction.

  `{:error, :not_found}` for a story the tenant cannot see.
  """
  @spec page(Ecto.UUID.t(), Ecto.UUID.t()) :: {:ok, page()} | {:error, :not_found}
  def page(tenant_id, story_id) do
    {:ok, result} =
      Repo.with_tenant(tenant_id, fn ->
        case page_story(tenant_id, story_id) do
          nil -> {:error, :not_found}
          story -> {:ok, read_page(tenant_id, story)}
        end
      end)

    with {:ok, page} <- result,
         do: {:ok, Map.put(page, :halted, Runners.custody_halted?(tenant_id))}
  end

  @doc """
  A page of the thread's entries, oldest first within it: the NEWEST page, or with
  `before_seq` the page before that entry — how the page walks backwards without re-reading
  anything else. `older_before_seq` is the `before_seq` of the next older page, or nil when this
  one reaches the start. `{:error, :not_found}` for a story the tenant cannot see.
  """
  @spec page_entries(Ecto.UUID.t(), Ecto.UUID.t(), pos_integer() | nil) ::
          {:ok, %{entries: [Entry.t()], older_before_seq: pos_integer() | nil}}
          | {:error, :not_found}
  def page_entries(tenant_id, story_id, before_seq \\ nil) do
    in_page_story(tenant_id, story_id, fn story -> read_entries(tenant_id, story, before_seq) end)
  end

  @doc """
  The page's checkpoints (as `get_thread/3` returns them) and `claim_checkpoints`: the
  claimant checkpoints of the story's CURRENT claim, oldest first, or none when the claim is not
  held — the only ones a human finding may bind to. What the page re-reads on its revalidation
  tick and after a write. `{:error, :not_found}` for a story the tenant cannot see.
  """
  @spec page_checkpoints(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, page_checkpoints()} | {:error, :not_found}
  def page_checkpoints(tenant_id, story_id) do
    in_page_story(tenant_id, story_id, fn story -> read_checkpoints(tenant_id, story) end)
  end

  defp in_page_story(tenant_id, story_id, fun) do
    {:ok, result} =
      Repo.with_tenant(tenant_id, fn ->
        case page_story(tenant_id, story_id) do
          nil -> {:error, :not_found}
          story -> {:ok, fun.(story)}
        end
      end)

    result
  end

  defp read_page(tenant_id, story) do
    tenant_id
    |> read_entries(story, nil)
    |> Map.merge(read_checkpoints(tenant_id, story))
    |> Map.merge(%{
      story: Map.take(story, [:id, :number, :title]),
      findings: latest_findings(tenant_id, story.id),
      repo: project_repo(tenant_id, story.project_id)
    })
  end

  defp read_entries(tenant_id, story, before_seq) do
    query =
      from e in Entry,
        where: e.tenant_id == ^tenant_id and e.story_id == ^story.id,
        order_by: [desc: e.seq],
        limit: ^(@max_entry_page + 1)

    query = if before_seq, do: where(query, [e], e.seq < ^before_seq), else: query
    {page, rest} = query |> Repo.all() |> Enum.split(@max_entry_page)
    entries = Enum.reverse(page)

    %{entries: entries, older_before_seq: if(rest == [], do: nil, else: hd(entries).seq)}
  end

  defp read_checkpoints(tenant_id, story) do
    {checkpoints, truncated?} = latest_checkpoints(tenant_id, story.id)

    claim_checkpoints =
      if is_nil(story.assigned_agent_id),
        do: [],
        else:
          Enum.filter(
            checkpoints,
            &(&1.kind == :checkpoint and &1.claim_epoch == story.claim_epoch)
          )

    %{
      checkpoints: checkpoints,
      checkpoints_truncated: truncated?,
      claim_checkpoints: claim_checkpoints
    }
  end

  defp latest_findings(tenant_id, story_id) do
    from(e in Entry,
      where: e.tenant_id == ^tenant_id and e.story_id == ^story_id and e.kind == :finding,
      order_by: [desc: e.seq],
      limit: ^@max_entry_page
    )
    |> Repo.all()
    |> Enum.reverse()
  end

  @doc """
  The unified diff of one checkpoint, fetched from the forge and never stored (US-45.7, PRD
  §6.1): the three-dot comparison of the base branch the checkpoint's OWN claim was placed on
  with the checkpoint's commit — the change as the merge gate judged it when that claim was
  current. A checkpoint of an earlier claim is judged against that claim's base, not the
  current one's (`DispatchPayload.dispatch_route/3` with the checkpoint's `claim_epoch`).

  A claim whose dispatch ledger recorded no base (a row written before the column existed, or
  no row at all) falls back to the intake source's CURRENT base branch, and the answer says so:
  `base_placed: false`.

  Every read runs in a short RLS transaction that is CLOSED before the forge is asked, so
  nothing holds a connection across GitHub. The forge call is bounded by the adapter
  (`Loopctl.Delivery.PullRequestSource.checkpoint_diff/3`); a slow or absent forge is an
  `{:error, reason}` for the caller to show beside a ledger that rendered without it.
  """
  @spec checkpoint_diff(Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, map()} | {:error, term()}
  def checkpoint_diff(tenant_id, story_id, checkpoint_id) do
    {:ok, target} =
      Repo.with_tenant(tenant_id, fn -> diff_target(tenant_id, story_id, checkpoint_id) end)

    with {:ok, story, source, checkpoint} <- target,
         {:ok, route} <- DispatchPayload.dispatch_route(tenant_id, story, checkpoint.claim_epoch) do
      base = DispatchPayload.placed_base_branch(route, source)

      # Read as the credential chosen for this (tenant, repository) (#936), like every forge
      # call: none is `{:error, :credential_unavailable}`, shown beside the ledger.
      with {:ok, repo} <- Credential.repo(tenant_id, source.repo_full_name),
           {:ok, diff} <-
             PullRequestSource.impl().checkpoint_diff(repo, base, checkpoint.commit_sha) do
        {:ok, Map.merge(diff, %{base: base, base_placed: is_binary(route.base_branch)})}
      end
    end
  end

  defp diff_target(tenant_id, story_id, checkpoint_id) do
    with {:ok, checkpoint_id} <- Ecto.UUID.cast(checkpoint_id) |> ok_or(:not_found),
         %Story{} = story <-
           Repo.one(from s in Story, where: s.tenant_id == ^tenant_id and s.id == ^story_id) ||
             {:error, :not_found},
         %Checkpoint{} = checkpoint <-
           checkpoint_of(tenant_id, story_id, checkpoint_id) || {:error, :not_found},
         {:ok, source} <- project_source(tenant_id, story.project_id) do
      {:ok, story, source, checkpoint}
    end
  end

  defp ok_or({:ok, value}, _reason), do: {:ok, value}
  defp ok_or(:error, reason), do: {:error, reason}

  defp page_story(tenant_id, story_id) do
    Repo.one(
      from s in Story,
        where: s.tenant_id == ^tenant_id and s.id == ^story_id,
        select: %{
          id: s.id,
          number: s.number,
          title: s.title,
          project_id: s.project_id,
          claim_epoch: s.claim_epoch,
          assigned_agent_id: s.assigned_agent_id
        }
    )
  end

  # The project's source by the ONE rule the gates use (`Intake.select_project_source/2`),
  # read here under RLS rather than on `AdminRepo`.
  defp project_source(tenant_id, project_id) do
    tenant_id
    |> Intake.live_sources_query()
    |> where([s], s.project_id == ^project_id)
    |> Repo.all()
    |> Intake.select_project_source(project_id)
  end

  defp project_repo(tenant_id, project_id) do
    case project_source(tenant_id, project_id) do
      {:ok, source} -> source.repo_full_name
      {:error, _reason} -> nil
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
    tenant_id |> story_row(story_id) |> select([s], struct(s, ^@story_fields))
  end

  defp story_row(tenant_id, story_id),
    do: from(s in Story, where: s.id == ^story_id and s.tenant_id == ^tenant_id)

  @doc false
  # The story's whole row, or nil, under the caller's `Repo.with_tenant/2`.
  @spec story(Ecto.UUID.t(), Ecto.UUID.t()) :: Story.t() | nil
  def story(tenant_id, story_id), do: Repo.one(story_row(tenant_id, story_id))

  @doc false
  # The checkpoint `checkpoint_id` of THIS story, or nil: another story's is none.
  @spec checkpoint_of(Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t()) :: Checkpoint.t() | nil
  def checkpoint_of(tenant_id, story_id, checkpoint_id) do
    Repo.one(
      from c in Checkpoint,
        where: c.id == ^checkpoint_id and c.tenant_id == ^tenant_id and c.story_id == ^story_id
    )
  end

  @doc """
  Copies the merge gate's evidence onto a checkpoint (US-45.6, AC-45.6.1): `record` is stored
  under `key` in the checkpoint's `gate_evidence`, replacing that key and leaving every other
  one.

  NEVER OVER A NEWER READ (US-45.6 review round 1, finding 6). Two evaluations can overlap,
  and the slower one may have read earlier: without a guard it would write a stale "pending"
  over the green record an allow was granted on. A record carrying `"read_at"` (ISO 8601 UTC,
  which orders as text) replaces only a stored one read strictly earlier; one read no later
  than what is stored changes nothing and is answered `:superseded`, so a caller about to act
  on it knows it did not land. One identical to what is stored, `read_at` aside, is `:ok`
  with no write.

  Not a thread WRITE in the claimant's sense — the gate, not a principal, records what the
  forge said about a commit — so it takes no story lock and no claim fence. Its lock wait is
  bounded and contention is `{:error, :busy}`, counted as `[:loopctl, :threads, :busy]`.
  `{:error, :not_found}` when the story has no such checkpoint.
  """
  @spec record_gate_evidence(Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t(), String.t(), map()) ::
          :ok | :superseded | {:error, :not_found | term()}
  def record_gate_evidence(tenant_id, story_id, checkpoint_id, key, record)
      when is_binary(key) and is_map(record) do
    Stages.answering_busy(tenant_id, [:loopctl, :threads, :busy], "gate evidence write", fn ->
      tenant_id
      |> Repo.with_tenant(fn ->
        write_gate_evidence(tenant_id, story_id, checkpoint_id, key, record)
      end)
      |> case do
        {:ok, answer} -> answer
        {:error, _reason} = error -> error
      end
    end)
  end

  @doc """
  Records a `base_update` checkpoint — the base branch merged INTO the thread by loopctl's
  GitHub App — and takes the stage machine's `ci -> ci` `:base_updated` edge onto it, in ONE
  transaction (US-45.5, AC-45.5.4 and AC-45.5.7).

  A CONTROL-PLANE write with NO HTTP route: `Loopctl.Delivery.MergeExecutor` is its only
  caller, having made the commit itself. It therefore bypasses the claimant fence
  (`record_checkpoint/3`'s), which is there because a claimant's report is a claim about a
  commit loopctl did not make. What fences it instead, read under the story's lock:

  - `parent_checkpoint_id` is a checkpoint of THIS story under its CURRENT claim, else
    `{:error, :not_found}` / `{:error, :stale_claim_epoch}`
  - the stage row is at `ci` and its allow names the parent's commit
    (`Loopctl.Delivery.Stages.follow_base_update/4`), else `:stale_stage` /
    `:allow_not_for_parent`. So a base update exists only for the checkpoint the gate last
    allowed, and never outlives the edge that makes it the head.

  The caller must have verified what only the forge knows: that `commit_sha` is GitHub's
  clean merge of the base into the parent, with the parent as its FIRST parent, and that
  `tree_sha` is that commit's tree.

  Idempotent: the same commit recorded again under the same claim, with the same parent and
  tree, answers `{:ok, checkpoint, :existing}` and writes nothing. The same commit with a
  different parent or tree is `checkpoint_conflict`.

  ## Options

  - `:commit_sha`, `:tree_sha` (required) — lowercase hex, one object format
  - `:note` — the entry body; defaults to naming the merge
  - `:actor_label` — on the stage events
  """
  @spec record_base_update(Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, Checkpoint.t(), :created | :existing} | {:error, term()}
  def record_base_update(tenant_id, story_id, parent_checkpoint_id, opts) do
    commit_sha = Keyword.fetch!(opts, :commit_sha)
    tree_sha = Keyword.fetch!(opts, :tree_sha)

    with :ok <- valid_sha(commit_sha, "commit_sha"),
         :ok <- valid_sha(tree_sha, "tree_sha"),
         :ok <- same_object_format(commit_sha, tree_sha) do
      in_story_lock(tenant_id, story_id, fn ->
        base_update_locked(tenant_id, story_id, parent_checkpoint_id, opts)
      end)
    end
  end

  @doc "The principal a `base_update` checkpoint's entry is recorded under."
  @spec merge_executor_principal() :: String.t()
  def merge_executor_principal, do: @merge_executor_principal

  @doc """
  Records the squash commit the merge executor created for `checkpoint_id` as its
  `merge_commit_sha`, the step IMMEDIATELY before the executor moves the base ref (US-45.5,
  AC-45.5.2), so a retry whose acknowledgement was lost can ask whether that commit reached
  the base.

  FENCED, and the fence is checked first, on every call, a resend of the same sha included:
  the story must still be at `ci` under claim `claim_epoch` with its allow naming this
  checkpoint's commit (`Loopctl.Delivery.Stages.mergeable_in/4`, under the story's and the
  row's locks). Otherwise `{:error, {:not_mergeable, reason}}` and nothing is written, so an
  executor whose story was released, moved or re-judged since it read them never moves the
  base. The ref update itself is an HTTP call and cannot run under this lock; what a change
  landing between this commit and that call leaves behind is the executor's to detect (a merge
  found on the base with the story not at `ci`).

  Then a compare-and-set: it writes only while the stored value is still `expected` (`nil`
  for a first squash). Otherwise `{:error, {:merge_commit_moved, stored}}`, so two executors
  cannot each believe their own commit is the recorded one. The value already stored is `:ok`.
  No HTTP route. Lock waits are bounded (`{:error, :busy}`); `{:error, {:not_mergeable,
  :not_found}}` for a story or checkpoint not in the tenant.
  """
  @spec record_merge_commit(
          Ecto.UUID.t(),
          Ecto.UUID.t(),
          Ecto.UUID.t(),
          String.t() | nil,
          String.t(),
          non_neg_integer()
        ) :: :ok | {:error, term()}
  def record_merge_commit(tenant_id, story_id, checkpoint_id, expected, merge_commit_sha, epoch) do
    with :ok <- valid_sha(merge_commit_sha, "merge_commit_sha") do
      write = fn ->
        merge_commit_locked(
          tenant_id,
          story_id,
          checkpoint_id,
          {expected, merge_commit_sha},
          epoch
        )
      end

      Stages.answering_busy(tenant_id, [:loopctl, :threads, :busy], "merge commit write", fn ->
        tenant_id |> Repo.with_tenant(write) |> unwrap_write()
      end)
    end
  end

  defp unwrap_write({:ok, answer}), do: answer
  defp unwrap_write({:error, _reason} = error), do: error

  defp merge_commit_locked(tenant_id, story_id, checkpoint_id, {expected, merge_sha}, epoch) do
    Capacity.set_lock_timeout!(Repo)

    with {:checkpoint, %Checkpoint{} = checkpoint} <-
           {:checkpoint, checkpoint_of(tenant_id, story_id, checkpoint_id)},
         :ok <- Stages.mergeable_in(tenant_id, story_id, epoch, checkpoint.commit_sha) do
      stored =
        Repo.one(
          from c in Checkpoint,
            where: c.id == ^checkpoint_id and c.tenant_id == ^tenant_id,
            lock: "FOR UPDATE",
            select: c.merge_commit_sha
        )

      compare_and_set_merge_commit(tenant_id, checkpoint_id, stored, expected, merge_sha)
    else
      {:checkpoint, nil} -> {:error, {:not_mergeable, :not_found}}
      {:error, reason} -> {:error, {:not_mergeable, reason}}
    end
  end

  defp compare_and_set_merge_commit(_tenant_id, _id, merge_sha, _expected, merge_sha), do: :ok

  defp compare_and_set_merge_commit(tenant_id, id, expected, expected, merge_sha) do
    {1, _} =
      from(c in Checkpoint, where: c.id == ^id and c.tenant_id == ^tenant_id)
      |> Repo.update_all(set: [merge_commit_sha: merge_sha, updated_at: now()])

    :ok
  end

  defp compare_and_set_merge_commit(_tenant_id, _id, stored, _expected, _merge_sha),
    do: {:error, {:merge_commit_moved, stored}}

  @doc """
  How many `base_update` checkpoints lead, parent to parent, from `checkpoint_id` back to the
  claimant checkpoint they were merged into: `0` for a claimant checkpoint. The executor's
  bound on consecutive base updates of one change reads it (US-45.5). Bounded by the story's
  own rows; a cycle is impossible (a checkpoint's parent is recorded before it) and guarded.
  """
  @spec base_update_depth(Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def base_update_depth(tenant_id, story_id, checkpoint_id) do
    Stages.answering_busy(tenant_id, [:loopctl, :threads, :busy], "thread read", fn ->
      tenant_id
      |> Repo.with_tenant(fn ->
        Repo.all(
          from c in Checkpoint,
            where: c.tenant_id == ^tenant_id and c.story_id == ^story_id,
            select: {c.id, {c.kind, c.parent_checkpoint_id}}
        )
      end)
      |> case do
        {:ok, rows} -> {:ok, depth(Map.new(rows), checkpoint_id, 0)}
        {:error, _reason} = error -> error
      end
    end)
  end

  defp depth(by_id, id, count) do
    case Map.get(by_id, id) do
      {:base_update, parent} when count < map_size(by_id) -> depth(by_id, parent, count + 1)
      _claimant_or_unknown -> count
    end
  end

  defp now, do: DateTime.utc_now()

  defp base_update_locked(tenant_id, story_id, parent_id, opts) do
    commit_sha = Keyword.fetch!(opts, :commit_sha)
    tree_sha = Keyword.fetch!(opts, :tree_sha)

    with {:story, %Story{} = story} <- {:story, locked_story(tenant_id, story_id)},
         {:parent, %Checkpoint{} = parent} <-
           {:parent, checkpoint_of(tenant_id, story_id, parent_id)},
         :ok <- epoch_current(story, parent.claim_epoch) do
      case checkpoint_by_sha(tenant_id, story_id, commit_sha, story.claim_epoch) do
        nil ->
          insert_base_update(tenant_id, story, parent, commit_sha, tree_sha, opts)

        %Checkpoint{kind: :base_update, parent_checkpoint_id: ^parent_id, tree_sha: ^tree_sha} =
            existing ->
          {:ok, existing, :existing, []}

        _different ->
          conflict("checkpoint_conflict", "commit_sha is already recorded as another checkpoint")
      end
    else
      {:story, nil} -> {:error, :not_found}
      {:parent, nil} -> {:error, :not_found}
      error -> error
    end
  end

  # The LOCK ORDER is the one every writer here keeps: the story (held FOR SHARE by now), the
  # stage row (`follow_base_update/4`), and the audit chain LAST (`insert_entry/4`). Taking
  # the edge after the entry would hold the chain head while waiting for a stage row that a
  # chained transition holds while waiting for the chain.
  defp insert_base_update(tenant_id, story, parent, commit_sha, tree_sha, opts) do
    previous = latest_checkpoint(tenant_id, story.id)

    checkpoint =
      Repo.insert!(%Checkpoint{
        tenant_id: tenant_id,
        story_id: story.id,
        seq: if(previous, do: previous.seq + 1, else: 1),
        kind: :base_update,
        commit_sha: commit_sha,
        tree_sha: tree_sha,
        parent_checkpoint_id: parent.id,
        claim_epoch: story.claim_epoch
      })

    Stages.follow_base_update(
      tenant_id,
      story.id,
      %{id: checkpoint.id, commit_sha: commit_sha, parent_commit_sha: parent.commit_sha},
      actor_label: Keyword.get(opts, :actor_label, @merge_executor_principal)
    )

    entry =
      Entry.system_changeset(%{
        kind: :checkpoint,
        idempotency_key: @reserved_key_prefix <> "base_update:#{commit_sha}:#{story.claim_epoch}",
        body:
          Keyword.get(opts, :note) ||
            "base update #{commit_sha}: the base branch merged into checkpoint " <>
              parent.commit_sha,
        checkpoint_id: checkpoint.id
      })

    adopted = %{
      "commit_sha" => commit_sha,
      "tree_sha" => tree_sha,
      "claim_epoch" => story.claim_epoch,
      "checkpoint_seq" => checkpoint.seq,
      "checkpoint_kind" => "base_update",
      "parent_checkpoint_id" => parent.id
    }

    entry_opts = [
      author_principal: @merge_executor_principal,
      actor_lineage: [],
      adopted: adopted
    ]

    with {:ok, _entry, :created, chained} <-
           insert_entry(tenant_id, story.id, entry, entry_opts) do
      {:ok, checkpoint, :created, chained}
    end
  end

  defp write_gate_evidence(tenant_id, story_id, checkpoint_id, key, record) do
    Capacity.set_lock_timeout!(Repo)

    stored =
      Repo.one(
        from c in Checkpoint,
          where: c.id == ^checkpoint_id and c.tenant_id == ^tenant_id,
          where: c.story_id == ^story_id,
          lock: "FOR UPDATE",
          select: %{present: true, record: fragment("?->?", c.gate_evidence, ^key)}
      )

    case evidence_write(stored, record) do
      :write ->
        {1, _} =
          from(c in Checkpoint, where: c.id == ^checkpoint_id)
          |> update([c],
            set: [gate_evidence: fragment("? || ?", c.gate_evidence, ^%{key => record})]
          )
          |> Repo.update_all([])

        :ok

      # Same judgement, read later: only the stored `read_at` moves, so a slower evaluation
      # that read in between can no longer pass for the newer one (#910 round 2, finding 3).
      :advance_read_at ->
        {1, _} =
          from(c in Checkpoint, where: c.id == ^checkpoint_id)
          |> update([c],
            set: [
              gate_evidence:
                fragment(
                  "jsonb_set(?, ARRAY[?, 'read_at'], to_jsonb(?::text))",
                  c.gate_evidence,
                  ^key,
                  ^Map.get(record, "read_at")
                )
            ]
          )
          |> Repo.update_all([])

        :ok

      answer ->
        answer
    end
  end

  # The decision, taken under the row lock so two evaluations cannot both think they are the
  # newer one. A record read no LATER than the stored one is `:superseded`, never `:ok`: the
  # allow path must not record an allow on evidence that did not land (round 2, finding 4).
  # One that says exactly what is stored already, read_at aside, rewrites nothing but the
  # stored `read_at` (when it is later), so a CI wait polled for hours rewrites the judgement
  # only when it moves (finding 6) and the ordering guard stays current.
  defp evidence_write(nil, _record), do: {:error, :not_found}
  defp evidence_write(%{record: nil}, _record), do: :write

  defp evidence_write(%{record: stored}, record) do
    later? = later?(Map.get(record, "read_at"), Map.get(stored, "read_at"))
    same? = Map.delete(stored, "read_at") == Map.delete(record, "read_at")

    cond do
      same? and later? and is_binary(Map.get(record, "read_at")) -> :advance_read_at
      same? -> :ok
      not later? -> :superseded
      true -> :write
    end
  end

  # ISO 8601 UTC with fixed-width fractions orders as text (`CiEvidence.to_record/5`). A record
  # with no `read_at` makes no ordering claim and is written.
  defp later?(nil, _stored), do: true
  defp later?(_read_at, nil), do: true
  defp later?(read_at, stored) when is_binary(read_at) and is_binary(stored), do: read_at > stored
  defp later?(_read_at, _stored), do: true

  defp locked_story(tenant_id, story_id),
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
    # parent that git says is its descendant; a claim's first checkpoint has none. Kind
    # `checkpoint` only: a `base_update` is loopctl's merge commit, not the claimant's work,
    # and is never what a claimant checkpoint descends from in the thread (US-45.5).
    parent = latest_checkpoint(tenant_id, story_id, epoch, :checkpoint)

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
      # AC-45.7.4: the thread's FIRST checkpoint is when its page has work on it. The intent to
      # link the intake issue commits with it; the comment is posted later with nothing held.
      if is_nil(previous), do: IssueLinks.record_in(Repo, tenant_id, story_id)
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

  defp latest_checkpoint(tenant_id, story_id, epoch \\ :any, kind \\ :any) do
    query =
      from c in Checkpoint,
        where: c.tenant_id == ^tenant_id and c.story_id == ^story_id,
        order_by: [desc: c.seq],
        limit: 1

    query = if epoch == :any, do: query, else: where(query, [c], c.claim_epoch == ^epoch)
    query = if kind == :any, do: query, else: where(query, [c], c.kind == ^kind)
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
    if GitSha.valid?(value),
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
         "kind #{kind} is written by the review flow (a finding or verdict over the runner " <>
           "socket, a fix through the thread's fixes endpoint), not as an entry"}

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

  # The screen every caller-written entry passes before its transaction opens: the reserved
  # key prefix, and the secret scan of its body and key.
  defp screen(changeset, tenant_id, story_id) do
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

  # Matches `thread_entries_idempotency_uidx`, which is partial on `review_id IS NULL`: a
  # judgement's key belongs to its review, so an author's message may reuse it.
  defp entry_by_key(tenant_id, story_id, author, key) do
    Repo.one(
      from e in Entry,
        where:
          e.tenant_id == ^tenant_id and e.story_id == ^story_id and
            e.author_principal == ^author and e.idempotency_key == ^key and
            is_nil(e.review_id)
    )
  end

  # A judgement's key is scoped to its REVIEW (`thread_entries_review_idempotency_uidx`).
  defp entry_by_review_key(tenant_id, review_id, key) do
    Repo.one(
      from e in Entry,
        where:
          e.tenant_id == ^tenant_id and e.review_id == ^review_id and
            e.idempotency_key == ^key
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
        if checkpoint_of(tenant_id, story_id, checkpoint_id),
          do: :ok,
          else: {:error, :unprocessable_entity, "checkpoint_id is not a checkpoint of this story"}
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
  # Reviews (US-45.3). Every rule is `Loopctl.Threads.Reviews`'; the writes are here.
  # ---------------------------------------------------------------------------

  # THE halt check of the thread — judgements, fixes, human findings, and the thread page's
  # banner (`page/3`) — and it is `Runners.custody_halted?/1`, the one `Loopctl.Delivery.Placement`
  # uses, so none of them can disagree. Read FRESH: a judgement decides what may merge, which is
  # custody progress a halted tenant must not make.
  defp not_halted(tenant_id) do
    if Runners.custody_halted?(tenant_id), do: {:error, :tenant_halted}, else: :ok
  end

  defp review_locked(tenant_id, story_id, opts) do
    dispatch_id = Keyword.fetch!(opts, :dispatch_id)
    runner_id = Keyword.fetch!(opts, :runner_id)
    agent_id = Keyword.fetch!(opts, :agent_id)

    with {:story, %Story{} = story} <- {:story, locked_story(tenant_id, story_id)},
         nil <- placed_before(tenant_id, story_id, dispatch_id, runner_id),
         :ok <- Reviews.claim_current(story, story.claim_epoch),
         {:ok, checkpoint} <- Reviews.latest_checkpoint(tenant_id, story),
         {:ok, round} <- Reviews.placeable_round(tenant_id, story),
         :ok <- Reviews.reviewer_separate(tenant_id, story, agent_id) do
      insert_review(tenant_id, story, checkpoint, round, opts)
    else
      {:story, nil} -> {:error, :not_found}
      other -> other
    end
  end

  # The same placement again is answered from its row; the id under another story or runner
  # is a different placement reusing it. So is an id the runner LEDGER already holds for
  # anything but this review: the push would leave that row in place (`record_sent/3` does
  # nothing on conflict), and this review would be bound to another dispatch's session.
  defp placed_before(tenant_id, story_id, dispatch_id, runner_id) do
    case Repo.one(
           from r in Review, where: r.tenant_id == ^tenant_id and r.dispatch_id == ^dispatch_id
         ) do
      nil ->
        ledger_free(tenant_id, story_id, dispatch_id, runner_id)

      %Review{story_id: ^story_id, runner_id: ^runner_id} = review ->
        {:ok, review, :existing, []}

      %Review{} ->
        conflict("dispatch_id_conflict", "dispatch_id names another review")
    end
  end

  defp ledger_free(tenant_id, story_id, dispatch_id, runner_id) do
    case Repo.one(
           from d in DispatchRecord,
             where: d.tenant_id == ^tenant_id and d.dispatch_id == ^dispatch_id,
             select: {d.kind, d.story_id, d.runner_id}
         ) do
      nil -> nil
      {"review", ^story_id, ^runner_id} -> nil
      _other -> conflict("dispatch_id_conflict", "dispatch_id names another runner dispatch")
    end
  end

  # The unique index on `(tenant_id, dispatch_id)` is what decides between two placements
  # reusing one id on DIFFERENT stories: each holds only its own story's lock, so neither sees
  # the other in `placed_before/4`, and the second insert meets the index. That is a
  # `dispatch_id_conflict`, not a 500.
  defp insert_review(tenant_id, story, checkpoint, round, opts) do
    %Review{
      tenant_id: tenant_id,
      story_id: story.id,
      dispatch_id: Keyword.fetch!(opts, :dispatch_id),
      runner_id: Keyword.fetch!(opts, :runner_id),
      agent_id: Keyword.fetch!(opts, :agent_id),
      claim_epoch: story.claim_epoch,
      checkpoint_id: checkpoint.id,
      round: round,
      placed_at_seq: next_entry_seq(tenant_id, story.id) - 1,
      placed_by: Keyword.fetch!(opts, :placed_by)
    }
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.unique_constraint(:dispatch_id,
      name: :thread_reviews_tenant_id_dispatch_id_index
    )
    |> Repo.insert()
    |> case do
      {:ok, review} -> chain_review(tenant_id, story, review)
      {:error, _taken} -> conflict("dispatch_id_conflict", "dispatch_id names another review")
    end
  end

  defp chain_review(tenant_id, story, review) do
    # The runner's credential is a plain key no dispatch minted, and loopctl places the
    # review itself, so the lineage is an ATTESTED empty one, as `RunnerStages` states it.
    with {:ok, chain_entry} <-
           AuditChain.append_in_tenant_transaction(tenant_id, %{
             action: "thread_review_placed",
             actor_lineage: [],
             entity_type: "story",
             entity_id: story.id,
             payload: %{
               "review_id" => review.id,
               "dispatch_id" => review.dispatch_id,
               "runner_id" => review.runner_id,
               "agent_id" => review.agent_id,
               "checkpoint_id" => review.checkpoint_id,
               "claim_epoch" => review.claim_epoch,
               "round" => review.round
             }
           }) do
      {:ok, review, :created, [chain_entry]}
    end
  end

  defp judgement_changeset(attrs) do
    kind = Map.get(attrs, "kind")

    changeset =
      Entry.changeset(%Entry{}, %{
        "kind" => kind,
        "idempotency_key" => Map.get(attrs, "idempotency_key"),
        "body" => Map.get(attrs, "body")
      })

    cond do
      kind not in ["finding", "verdict"] ->
        {:error, :unprocessable_entity, "a judgement is a finding or a verdict"}

      not changeset.valid? ->
        {:error, changeset}

      kind == "verdict" ->
        {:ok, changeset}

      true ->
        finding_fields(changeset, attrs)
    end
  end

  defp finding_fields(changeset, attrs) do
    with {:ok, severity} <- Reviews.severity(Map.get(attrs, "severity")),
         {:ok, location} <- Reviews.location(Map.get(attrs, "location")),
         {:ok, introduced_by} <- Reviews.introduced_by(Map.get(attrs, "introduced_by")) do
      {:ok,
       Ecto.Changeset.change(changeset,
         severity: severity,
         location: location,
         introduced_by: introduced_by
       )}
    end
  end

  defp judgement_locked(tenant_id, story_id, dispatch_id, changeset, opts) do
    with {:story, %Story{} = story} <- {:story, locked_story(tenant_id, story_id)},
         {:review, %Review{} = review} <-
           {:review, bound_review(tenant_id, story_id, dispatch_id, opts)} do
      changeset =
        Ecto.Changeset.change(changeset,
          review_id: review.id,
          checkpoint_id: review.checkpoint_id
        )

      case entry_by_review_key(tenant_id, review.id, key_of(changeset)) do
        nil -> judge_new(story, review, changeset, opts)
        existing -> existing |> replay(changeset) |> as_judgement(review)
      end
    else
      {:story, nil} -> {:error, :not_found}
      {:review, nil} -> {:error, :unknown_review}
    end
  end

  # Bound by the dispatch AND the runner holding it: the review a runner may judge under is
  # only ever the one loopctl pushed to that runner.
  defp bound_review(tenant_id, story_id, dispatch_id, opts) do
    runner_id = Keyword.fetch!(opts, :runner_id)

    Repo.one(
      from r in Review,
        where:
          r.tenant_id == ^tenant_id and r.story_id == ^story_id and
            r.dispatch_id == ^dispatch_id and r.runner_id == ^runner_id
    )
  end

  defp key_of(changeset), do: Ecto.Changeset.get_field(changeset, :idempotency_key)

  # A resend answers what was RECORDED: a verdict's resend carries the escalation its first
  # delivery wrote, if it wrote one, so the runner hears the same outcome whichever delivery
  # it heard.
  defp as_judgement({:ok, %Entry{kind: :verdict} = entry, :existing, []}, review),
    do: {:ok, %{entry: entry, escalation: recorded_escalation(review)}, :existing, []}

  defp as_judgement({:ok, entry, :existing, []}, _review),
    do: {:ok, %{entry: entry, escalation: nil}, :existing, []}

  defp as_judgement(error, _review), do: error

  defp recorded_escalation(review) do
    Repo.one(
      from e in Entry,
        where:
          e.tenant_id == ^review.tenant_id and e.review_id == ^review.id and
            e.kind == :escalation
    )
  end

  # Every rule a NEW judgement meets, decided once under the lock: the claim the review
  # belongs to is still the story's, the reviewer is still separate, and the review may still
  # judge. `completed` is read once and reused for the ceiling a verdict may reach.
  #
  # The custody HALT is checked here, for new writes only: a resend of a judgement already
  # recorded is answered from its row before any rule, halt included, so a runner that lost
  # an ack during a halt still learns its write landed.
  defp judge_new(story, review, changeset, opts) do
    tenant_id = review.tenant_id

    with :ok <- not_halted(tenant_id),
         :ok <- new_write_allowed(opts),
         :ok <- Reviews.claim_current(story, review.claim_epoch),
         :ok <- Reviews.reviewer_separate(tenant_id, story, review.agent_id),
         completed = Reviews.completed(tenant_id, story),
         :ok <- Reviews.judgeable(review, completed) do
      insert_judgement(
        Ecto.Changeset.get_field(changeset, :kind),
        story,
        review,
        changeset,
        opts,
        completed
      )
    end
  end

  defp insert_judgement(:finding, story, review, changeset, opts, _completed) do
    introduced_by = Ecto.Changeset.get_field(changeset, :introduced_by)

    with :ok <- Reviews.introduced_by_allowed(review, introduced_by),
         {:ok, entry, :created, chained} <-
           insert_entry(review.tenant_id, story.id, changeset, judge_opts(opts)) do
      {:ok, %{entry: entry, escalation: nil}, :created, chained}
    end
  end

  defp insert_judgement(:verdict, story, review, changeset, opts, completed) do
    with {:ok, verdict, :created, chained} <-
           insert_entry(review.tenant_id, story.id, changeset, judge_opts(opts)),
         {:ok, escalation, escalation_chained} <-
           ceiling_escalation(story, review, completed, verdict.seq) do
      {:ok, %{entry: verdict, escalation: escalation}, :created, chained ++ escalation_chained}
    end
  end

  defp judge_opts(opts),
    do: [author_principal: Keyword.fetch!(opts, :author_principal), actor_lineage: []]

  @review_ceiling_principal "control:review_ceiling"

  @doc false
  # The principal a `review_ceiling` escalation entry is written under, which
  # `Loopctl.Workers.ReviewCeilingWorker` reads the entries back by.
  @spec review_ceiling_principal() :: String.t()
  def review_ceiling_principal, do: @review_ceiling_principal

  # The round this verdict just completed reached the ceiling with a material finding: the
  # escalation is RECORDED here, in the verdict's transaction, and
  # `Loopctl.Workers.ReviewCeilingWorker` moves the stage until it lands.
  defp ceiling_escalation(story, review, completed, verdict_seq) do
    case Reviews.ceiling_material(review.tenant_id, story, review, completed, verdict_seq) do
      0 ->
        {:ok, nil, []}

      material ->
        changeset =
          %{
            kind: :escalation,
            idempotency_key: @reserved_key_prefix <> "review_ceiling:#{review.id}",
            body:
              "review_ceiling: round #{review.round} of #{Reviews.max_rounds()} left " <>
                "#{material} material finding(s) and no further round is placeable; the " <>
                "remedy is a rewrite, not another round",
            checkpoint_id: review.checkpoint_id
          }
          |> Entry.system_changeset()
          |> Ecto.Changeset.put_change(:review_id, review.id)

        with {:ok, entry, :created, chained} <-
               insert_entry(review.tenant_id, story.id, changeset,
                 author_principal: @review_ceiling_principal,
                 actor_lineage: []
               ),
             do: {:ok, entry, chained}
    end
  end

  defp valid(%Ecto.Changeset{valid?: true}), do: :ok
  defp valid(changeset), do: {:error, changeset}

  defp fix_checkpoint_given(changeset) do
    if Ecto.Changeset.get_field(changeset, :checkpoint_id),
      do: :ok,
      else:
        {:error,
         {:unprocessable_entity, "fix_checkpoint_required",
          "a fix is carried by a checkpoint: checkpoint_id is required"}}
  end

  # A resend is answered from its row before the fence, as a checkpoint's is.
  defp fix_locked(tenant_id, story_id, changeset, opts) do
    finding_ids = Ecto.Changeset.get_field(changeset, :finding_ids)
    author = Keyword.fetch!(opts, :author_principal)

    with {:story, %Story{} = story} <- {:story, locked_story(tenant_id, story_id)},
         nil <- entry_by_key(tenant_id, story_id, author, key_of(changeset)),
         :ok <-
           claimant_fence(
             story,
             Keyword.fetch!(opts, :agent_id),
             Keyword.fetch!(opts, :claim_epoch)
           ),
         {:ok, checkpoint} <-
           Reviews.fix_checkpoint(
             tenant_id,
             story,
             Ecto.Changeset.get_field(changeset, :checkpoint_id)
           ),
         :ok <- Reviews.answers_findings(tenant_id, story, finding_ids, checkpoint) do
      insert_entry(tenant_id, story_id, changeset,
        author_principal: author,
        actor_lineage: Keyword.fetch!(opts, :actor_lineage)
      )
    else
      {:story, nil} -> {:error, :not_found}
      %Entry{} = existing -> replay(existing, changeset)
      other -> other
    end
  end

  defp human_finding_checkpoint_given(changeset) do
    if Ecto.Changeset.get_field(changeset, :checkpoint_id),
      do: :ok,
      else:
        {:error,
         {:unprocessable_entity, "finding_checkpoint_required",
          "a finding binds to a checkpoint: checkpoint_id is required"}}
  end

  # A resend is answered from its row before any rule, halt included: the page that lost its
  # response must learn its finding landed, and a double submit must be one entry.
  defp human_finding_locked(tenant_id, story_id, changeset) do
    with {:story, %Story{} = story} <- {:story, locked_story(tenant_id, story_id)},
         nil <- entry_by_key(tenant_id, story_id, @human_principal, key_of(changeset)),
         :ok <- not_halted(tenant_id),
         {:ok, checkpoint} <-
           Reviews.human_finding_checkpoint(
             tenant_id,
             story,
             Ecto.Changeset.get_field(changeset, :checkpoint_id)
           ),
         :ok <-
           Reviews.human_introduced_by_allowed(
             tenant_id,
             story,
             checkpoint,
             Ecto.Changeset.get_field(changeset, :introduced_by)
           ) do
      with {:ok, entry, :created, chained} <-
             insert_entry(tenant_id, story_id, changeset,
               author_principal: @human_principal,
               actor_lineage: []
             ),
           {:ok, escalation, escalation_chained} <- human_ceiling(tenant_id, story, entry) do
        {:ok, %{entry: entry, escalation: escalation}, :created, chained ++ escalation_chained}
      end
    else
      {:story, nil} ->
        {:error, :not_found}

      %Entry{} = existing ->
        case replay(existing, changeset) do
          {:ok, entry, :existing, []} ->
            {:ok, %{entry: entry, escalation: recorded_ceiling(tenant_id, story_id, entry)},
             :existing, []}

          conflict ->
            conflict
        end

      other ->
        other
    end
  end

  # A material human finding once the claim's rounds are at the ceiling: the escalation a
  # ceiling verdict would have recorded, bound to the final review, recorded now — or the one
  # that verdict already recorded. A finding below material, or with rounds still to place,
  # escalates nothing: it counts in a round instead (`Reviews.round_findings/4`).
  defp human_ceiling(tenant_id, story, entry) do
    with true <- entry.severity in Reviews.material(),
         %Review{} = review <- Reviews.ceiling_review(tenant_id, story) do
      key = @reserved_key_prefix <> "review_ceiling:#{review.id}"

      case entry_by_review_key(tenant_id, review.id, key) do
        %Entry{} = recorded -> {:ok, {:already_escalated, recorded}, []}
        nil -> insert_human_ceiling(tenant_id, story, review, key)
      end
    else
      _below_material_or_open -> {:ok, nil, []}
    end
  end

  defp insert_human_ceiling(tenant_id, story, review, key) do
    changeset =
      %{
        kind: :escalation,
        idempotency_key: key,
        body:
          "review_ceiling: a material finding was recorded by #{@human_principal} after " <>
            "round #{review.round} of #{Reviews.max_rounds()}, and no further round is " <>
            "placeable; the remedy is a rewrite, not another round",
        checkpoint_id: review.checkpoint_id
      }
      |> Entry.system_changeset()
      |> Ecto.Changeset.put_change(:review_id, review.id)

    with {:ok, escalation, :created, chained} <-
           insert_entry(tenant_id, story.id, changeset,
             author_principal: @review_ceiling_principal,
             actor_lineage: []
           ),
         do: {:ok, {:escalated, escalation}, chained}
  end

  # What a resend of a human finding answers: what its FIRST delivery did, read from what was
  # recorded for it, never from the ceiling as it stands now. The escalation a human finding
  # records is written in the same transaction, straight after it (`human_ceiling/3`), so it is
  # the entry at the finding's seq plus one; anything else there is not this finding's doing,
  # and the resend answers plain "recorded".
  defp recorded_ceiling(tenant_id, story_id, entry) do
    next = entry.seq + 1

    case Repo.one(
           from e in Entry,
             where:
               e.tenant_id == ^tenant_id and e.story_id == ^story_id and e.seq == ^next and
                 e.kind == :escalation and e.author_principal == ^@review_ceiling_principal
         ) do
      nil -> nil
      escalation -> {:escalated, escalation}
    end
  end

  defp claimant_fence(story, agent_id, epoch) do
    with :ok <- Claimant.check(story, agent_id, epoch), do: lease(story)
  end

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

  defp announced({:error, {:error, _reason} = error}), do: error
  defp announced({:error, {:error, _status, _message} = error}), do: error
  # A refusal `Loopctl.Delivery.Stages.follow_base_update/4` rolled the transaction back with.
  defp announced({:error, reason}), do: {:error, reason}

  defp next_entry_seq(tenant_id, story_id) do
    Repo.one(
      from e in Entry,
        where: e.tenant_id == ^tenant_id and e.story_id == ^story_id,
        select: coalesce(max(e.seq), 0)
    ) + 1
  end
end
