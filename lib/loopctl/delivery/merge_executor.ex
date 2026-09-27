defmodule Loopctl.Delivery.MergeExecutor do
  @moduledoc """
  loopctl merges a THREAD-mode story itself (US-45.5, Epic 45 PRD §4 items 3-5): it squashes
  the checkpoint the merge gate allowed onto the base branch as loopctl's GitHub App, by
  compare-and-swap. Run by `Loopctl.Workers.ThreadMergeWorker`, which
  `Loopctl.Delivery.MergePrecondition` enqueues when it records a thread-mode allow.

  ## It trusts nothing the enqueue said

  The job carries only the story. Every run re-reads, before touching the forge: the stage row
  at `ci` with a `merge_gate_allowed_sha`; the allow's own event naming a checkpoint
  (`Loopctl.Delivery.Stages.last_allow_query/2`) whose sha is that one; the claim placed in
  `thread` mode; and the judged checkpoint (`Loopctl.Threads.claim_checkpoints/2`) being
  EXACTLY the allowed one. Anything else merges nothing and answers `{:skipped, reason}`:
  there is no allow for what is there now, so there is nothing for the executor to do, and
  the gate's next evaluation decides what the story needs.

  ## The squash (AC-45.5.2)

  1. The base head. A `merge_commit_sha` already recorded on the checkpoint that the base
     CONTAINS is `:already_merged` (AC-45.5.3): the story moves to `merged` at it, and nothing
     is written to the forge. That is the retry of a ref update whose acknowledgement was
     lost, and the question it asks — is that commit an ancestor of the base — survives other
     merges landing in between, which a tree comparison would not.
  2. The checkpoint commit's tree, read from the forge. Not the recorded `tree_sha`:
     `tree_mismatch`, escalated, no write.
  3. FRESHNESS (AC-45.5.8): the base head must still be the allow's `base_sha`, the merge
     base the judged three-dot diff is relative to, and the checkpoint must contain it.
     Otherwise the base-update path below: squashing the checkpoint's tree onto a newer base
     would silently revert every base commit the judged diff never saw.
  4. A checkpoint whose tree equals the base's is `empty_change`, escalated, never merged.
  5. The squash commit: the checkpoint's tree, the base head as its ONLY parent, the message
     of `Loopctl.Delivery.MergeMessage`. A commit recorded earlier with exactly that tree and
     parent is reused, so a retry converges on one commit.
  6. Its sha is RECORDED on the checkpoint (`Loopctl.Threads.record_merge_commit/5`, a
     compare-and-set) BEFORE the ref moves.
  7. The ref update, `force: false`. That is the compare-and-swap: GitHub refuses a move that
     is not a fast-forward, so a base that moved since step 1 cannot be overwritten, and the
     base-update path runs instead (AC-45.5.4).

  ## The base-update path (AC-45.5.4)

  The thread branch must still name the checkpoint (otherwise the head moved, and that is
  `:base_moved`). The App merges the base INTO the thread branch (`POST /repos/:repo/merges`);
  a commit whose first parent is the checkpoint is recorded as a `base_update` checkpoint and
  the story stays at `ci` over `:base_updated`, in one transaction
  (`Loopctl.Threads.record_base_update/4`), keeping its review verdict and custody. The gate
  judges that head again, green CI on its exact sha included (AC-45.5.9). A conflict goes back
  to `implementing` over `:base_moved`.

  ## Failure, retries and races (SOUL rule 9)

  - A TRANSIENT forge fault (`MergePrecondition.transient?/1`) is `{:retry, reason}`: the
    worker returns an error and Oban retries. The final attempt escalates it
    (`forge_unavailable`) rather than leaving an allowed story sitting at `ci`.
  - Any other refusal escalates over `{:ci, :escalated, :merge_gate}`, naming the reason with
    a `merge_executor` prefix — `app_unconfigured` (the App's env unset), `tree_mismatch`,
    `empty_change`, a ref update GitHub refused for another reason (a ruleset), and so on.
  - A lost acknowledgement anywhere is answered by re-reading, never by remembering: a lost
    ref-update ack by step 1, a lost stage write by the same, a lost `merge_commit_sha`
    write by step 5 reusing nothing and recording afresh.
  - Two runs cannot overlap: the worker is unique per story while one is waiting, running or
    retrying. If they could, the ref update is still a compare-and-swap and the recorded
    commit a compare-and-set, so at most one squash reaches the base.
  - A base merge whose acknowledgement is lost has MOVED the thread branch with nothing
    recorded. The retry sees a branch head nobody reported and sends the story back over
    `:base_moved`, never adopting it: loopctl cannot tell its own merge from a zombie's push
    after the fact, and only GitHub's answer to the merge request certifies the tree.
  """

  require Logger

  alias Loopctl.Delivery.Claimant
  alias Loopctl.Delivery.DispatchPayload
  alias Loopctl.Delivery.MergeForge
  alias Loopctl.Delivery.MergeMessage
  alias Loopctl.Delivery.MergePrecondition
  alias Loopctl.Delivery.Stages
  alias Loopctl.Delivery.StoryStage
  alias Loopctl.Intake
  alias Loopctl.Repo
  alias Loopctl.Threads
  alias Loopctl.Threads.Checkpoint
  alias Loopctl.WorkBreakdown.Stories

  @actor_label "control:merge_executor"

  # The `story_stages_text_bounds` CHECK, with room, as the gate budgets its own reasons.
  @reason_budget 3_900

  @type outcome ::
          {:merged, String.t()}
          | {:already_merged, String.t()}
          | :base_updated
          | {:base_moved, term()}
          | {:escalated, term()}
          | {:skipped, term()}
          | {:retry, term()}

  @doc """
  One run for `story_id`. `final?` is true on the worker's last attempt, where a transient
  fault escalates instead of asking for a retry.
  """
  @spec run(Ecto.UUID.t(), Ecto.UUID.t(), boolean()) :: outcome()
  def run(tenant_id, story_id, final? \\ false) do
    case context(tenant_id, story_id) do
      {:ok, ctx} ->
        ctx
        |> Map.put(:final?, final?)
        |> execute()
        |> log(ctx)

      {:skip, reason} ->
        Logger.info(
          "merge_executor merged nothing: #{inspect(reason)} tenant_id=#{tenant_id} " <>
            "story_id=#{story_id}"
        )

        {:skipped, reason}

      {:error, reason} ->
        if MergePrecondition.transient?(reason), do: {:retry, reason}, else: {:skipped, reason}
    end
  end

  @doc "The label the executor's stage writes and thread entries carry."
  @spec actor_label() :: String.t()
  def actor_label, do: @actor_label

  # -- what the run is allowed to act on --------------------------------------------------

  defp context(tenant_id, story_id) do
    with {:ok, story} <- Stories.get_story(tenant_id, story_id),
         {:ok, stage} <- stage_at_ci(tenant_id, story_id, story),
         {:ok, allow} <- recorded_allow(tenant_id, story_id, stage),
         {:ok, route} <- DispatchPayload.dispatch_route(tenant_id, story),
         :ok <- thread_mode(route),
         {:ok, checkpoint} <- allowed_checkpoint(tenant_id, story_id, allow),
         {:ok, source} <- Intake.source_for_project(tenant_id, story.project_id),
         {:ok, branch} <- DispatchPayload.thread_branch(route, story, stage.branch) do
      {:ok,
       %{
         tenant_id: tenant_id,
         story: story,
         allow: allow,
         checkpoint: checkpoint,
         repo: source.repo_full_name,
         base_branch: route.base_branch || source.base_branch,
         branch: branch
       }}
    end
  end

  defp stage_at_ci(tenant_id, story_id, %{claim_epoch: epoch}) do
    case Stages.get(tenant_id, story_id) do
      nil -> {:skip, :no_stage}
      %StoryStage{stage: :ci, claim_epoch: ^epoch} = row -> {:ok, row}
      %StoryStage{stage: :ci} -> {:skip, :stale_claim_epoch}
      %StoryStage{stage: stage} -> {:skip, {:not_at_ci, stage}}
    end
  end

  # The row's allow AND the event that recorded it, which names the checkpoint and the base.
  defp recorded_allow(_tenant_id, _story_id, %StoryStage{merge_gate_allowed_sha: nil}),
    do: {:skip, :no_allow}

  defp recorded_allow(tenant_id, story_id, %StoryStage{merge_gate_allowed_sha: sha}) do
    {:ok, allow} =
      Repo.with_tenant(tenant_id, fn -> Repo.one(Stages.last_allow_query(tenant_id, story_id)) end)

    case allow do
      %{sha: ^sha, checkpoint_id: id, base_sha: base} when is_binary(id) and is_binary(base) ->
        {:ok, allow}

      _other ->
        {:skip, :allow_names_no_checkpoint}
    end
  end

  defp thread_mode(%{mode: :thread}), do: :ok
  defp thread_mode(_route), do: {:skip, :not_thread_mode}

  # AC-45.5.1: the checkpoint the gate judges NOW must be the one the allow names.
  defp allowed_checkpoint(tenant_id, story_id, allow) do
    case Threads.claim_checkpoints(tenant_id, story_id) do
      {:ok, %{latest: %Checkpoint{id: id, commit_sha: sha} = checkpoint}}
      when id == allow.checkpoint_id and sha == allow.sha ->
        {:ok, checkpoint}

      {:ok, _other} ->
        {:skip, :allow_not_for_checkpoint}

      {:error, _reason} = error ->
        error
    end
  end

  # -- the squash ----------------------------------------------------------------------------

  defp execute(ctx) do
    forge = MergeForge.impl()

    with {:ok, session} <- forge.session(ctx.repo),
         ctx = Map.merge(ctx, %{forge: forge, session: session}),
         {:ok, base_head} <- forge.branch_head(session, ctx.base_branch) do
      squash(ctx, base_head)
    else
      {:error, reason} -> failed(ctx, reason)
    end
  end

  defp squash(ctx, base_head) do
    %{forge: forge, session: session, checkpoint: checkpoint} = ctx

    with :continue <- already_merged(ctx, base_head),
         {:ok, commit} <- forge.commit(session, checkpoint.commit_sha),
         :ok <- tree_matches(commit, checkpoint),
         :fresh <- fresh(ctx, base_head),
         {:ok, base_commit} <- forge.commit(session, base_head),
         :ok <- not_empty(base_commit, checkpoint),
         {:ok, merge_sha} <- squash_commit(ctx, base_head),
         :ok <- record_merge_commit(ctx, merge_sha) do
      case forge.update_ref(session, ctx.base_branch, merge_sha) do
        :ok -> merged(ctx, merge_sha)
        {:error, :not_fast_forward} -> update_base(ctx)
        {:error, reason} -> failed(ctx, reason)
      end
    else
      {:already_merged, sha} -> already(ctx, sha)
      :stale -> update_base(ctx)
      {:refuse, reason} -> escalate(ctx, reason)
      {:error, reason} -> failed(ctx, reason)
    end
  end

  defp already_merged(%{checkpoint: %Checkpoint{merge_commit_sha: nil}}, _base_head),
    do: :continue

  defp already_merged(ctx, base_head) do
    sha = ctx.checkpoint.merge_commit_sha

    case ctx.forge.ancestor?(ctx.session, sha, base_head) do
      {:ok, true} -> {:already_merged, sha}
      {:ok, false} -> :continue
      {:error, _reason} = error -> error
    end
  end

  defp tree_matches(%{tree_sha: tree}, %Checkpoint{tree_sha: tree}), do: :ok

  defp tree_matches(%{tree_sha: forge}, %Checkpoint{tree_sha: recorded}),
    do: {:refuse, {:tree_mismatch, forge, recorded}}

  # AC-45.5.8: the base the judged diff was relative to, and still contained by the work.
  defp fresh(%{allow: %{base_sha: base_head}} = ctx, base_head) do
    case ctx.forge.ancestor?(ctx.session, base_head, ctx.checkpoint.commit_sha) do
      {:ok, true} -> :fresh
      {:ok, false} -> :stale
      {:error, _reason} = error -> error
    end
  end

  defp fresh(_ctx, _base_head), do: :stale

  defp not_empty(%{tree_sha: tree}, %Checkpoint{tree_sha: tree}),
    do: {:refuse, {:empty_change, tree}}

  defp not_empty(_base_commit, _checkpoint), do: :ok

  # A commit recorded by an earlier attempt, with exactly this tree on exactly this base, is
  # reused: a retry converges on ONE squash commit rather than minting one per attempt.
  defp squash_commit(ctx, base_head) do
    case reusable(ctx, base_head) do
      {:ok, sha} ->
        {:ok, sha}

      :none ->
        ctx.forge.create_commit(ctx.session, %{
          tree: ctx.checkpoint.tree_sha,
          parents: [base_head],
          message: MergeMessage.build(ctx.story, thread_url(ctx.story))
        })
    end
  end

  defp reusable(%{checkpoint: %Checkpoint{merge_commit_sha: nil}}, _base_head), do: :none

  defp reusable(%{checkpoint: checkpoint} = ctx, base_head) do
    tree = checkpoint.tree_sha

    case ctx.forge.commit(ctx.session, checkpoint.merge_commit_sha) do
      {:ok, %{tree_sha: ^tree, parents: [^base_head]}} -> {:ok, checkpoint.merge_commit_sha}
      _stale_or_unreadable -> :none
    end
  end

  defp record_merge_commit(ctx, merge_sha) do
    %{tenant_id: tenant_id, story: story, checkpoint: checkpoint} = ctx

    case Threads.record_merge_commit(
           tenant_id,
           story.id,
           checkpoint.id,
           checkpoint.merge_commit_sha,
           merge_sha
         ) do
      :ok -> :ok
      {:error, :busy} -> {:error, :busy}
      # Another run recorded a different commit: this one must not move the ref with its own.
      {:error, reason} -> {:error, {:merge_commit_not_recorded, reason}}
    end
  end

  # -- the base-update path -------------------------------------------------------------------

  defp update_base(ctx) do
    %{forge: forge, session: session, checkpoint: checkpoint} = ctx

    with {:ok, head} <- forge.branch_head(session, ctx.branch),
         :ok <- branch_names_checkpoint(head, checkpoint),
         {:ok, merged} <- forge.merge(session, ctx.branch, ctx.base_branch, base_message(ctx)) do
      record_base_update(ctx, merged)
    else
      {:moved, reason} -> base_moved(ctx, reason)
      {:error, :merge_conflict} -> base_moved(ctx, :merge_conflict)
      {:error, reason} -> failed(ctx, reason)
    end
  end

  defp branch_names_checkpoint(sha, %Checkpoint{commit_sha: sha}), do: :ok
  defp branch_names_checkpoint(sha, _checkpoint), do: {:moved, {:thread_branch_moved, sha}}

  defp record_base_update(ctx, :up_to_date),
    do: escalate(ctx, {:base_update_unexpected, :up_to_date})

  # AC-45.5.7: only GitHub's merge whose FIRST parent is the allowed checkpoint is a base
  # update. Anything else means the branch moved between the read and the merge.
  defp record_base_update(%{checkpoint: %Checkpoint{commit_sha: parent}} = ctx, %{
         sha: sha,
         tree_sha: tree,
         parents: [parent | _]
       }) do
    case Threads.record_base_update(ctx.tenant_id, ctx.story.id, ctx.checkpoint.id,
           commit_sha: sha,
           tree_sha: tree,
           actor_label: @actor_label
         ) do
      {:ok, _checkpoint, _status} ->
        :base_updated

      {:error, reason} when reason in [:stale_stage, :stale_claim_epoch, :allow_not_for_parent] ->
        # The story moved on while the base merged: the gate will see a branch head nobody
        # reported and decide. Nothing here may adopt it.
        {:skipped, {:base_update_not_recorded, reason}}

      {:error, reason} ->
        failed(ctx, reason)
    end
  end

  defp record_base_update(ctx, %{parents: parents}),
    do: base_moved(ctx, {:thread_branch_moved, List.first(parents)})

  defp base_message(ctx) do
    "Merge #{ctx.base_branch} into #{ctx.branch} (loopctl base update)\n\n" <>
      "Loopctl-Story: #{ctx.story.id}"
  end

  # -- outcomes --------------------------------------------------------------------------------

  defp merged(ctx, sha) do
    case advance(ctx, {:ci, :merged, :forward}, effects: [merge_sha: sha]) do
      :ok -> {:merged, sha}
      {:error, reason} -> after_merge_failure(ctx, sha, reason)
    end
  end

  defp already(ctx, sha) do
    case merged(ctx, sha) do
      {:merged, ^sha} -> {:already_merged, sha}
      other -> other
    end
  end

  # The ref moved and the stage write did not land. A retry re-reads and adopts the recorded
  # commit (`already_merged/2`); a row some other writer already moved to `merged` at this
  # sha is the same outcome.
  defp after_merge_failure(ctx, sha, reason) do
    case Stages.get(ctx.tenant_id, ctx.story.id) do
      %StoryStage{stage: :merged, merge_sha: ^sha} -> {:merged, sha}
      _other -> {:retry, {:merged_not_recorded, reason}}
    end
  end

  # A head that moves is ordinary work while the claimant can still record a fix, and a
  # human's call when it cannot — the gate's own rule for a moved thread head, so a story
  # never loops ci -> implementing -> ci with nobody able to move it.
  defp base_moved(ctx, reason) do
    if Claimant.live?(ctx.story, DateTime.utc_now()) do
      case advance(ctx, {:ci, :implementing, :base_moved}, reason: reason_text(reason)) do
        :ok -> {:base_moved, reason}
        {:error, error} -> failed(ctx, {:transition_failed, :base_moved, error})
      end
    else
      escalate(ctx, {:claim_not_live, reason})
    end
  end

  defp failed(ctx, reason) do
    cond do
      not MergePrecondition.transient?(reason) -> escalate(ctx, reason)
      ctx.final? -> escalate(ctx, {:forge_unavailable, reason})
      true -> {:retry, reason}
    end
  end

  defp escalate(ctx, reason) do
    case advance(ctx, {:ci, :escalated, :merge_gate}, reason: reason_text(reason)) do
      :ok ->
        {:escalated, reason}

      {:error, error} ->
        Logger.warning(
          "merge_executor escalation not written story_id=#{ctx.story.id} " <>
            "tenant_id=#{ctx.tenant_id} reason=#{inspect(reason)} error=#{inspect(error)}"
        )

        {:retry, {:escalation_not_written, reason, error}}
    end
  end

  defp advance(ctx, transition, extra) do
    opts =
      [
        claim_epoch: ctx.story.claim_epoch,
        actor_label: @actor_label,
        actor_role: :agent,
        actor_lineage: []
      ] ++ extra

    case Stages.advance(ctx.tenant_id, ctx.story.id, transition, opts) do
      {:ok, _row} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp reason_text(reason) do
    chars = String.to_charlist("merge_executor: " <> inspect(reason))

    if length(chars) > @reason_budget,
      do: chars |> Enum.take(@reason_budget - 1) |> List.to_string() |> Kernel.<>("…"),
      else: List.to_string(chars)
  end

  defp thread_url(story), do: LoopctlWeb.Endpoint.url() <> "/api/v1/stories/#{story.id}/thread"

  defp log(outcome, ctx) do
    Logger.info(
      "merge_executor #{inspect(outcome)} tenant_id=#{ctx.tenant_id} story_id=#{ctx.story.id}"
    )

    outcome
  end
end
