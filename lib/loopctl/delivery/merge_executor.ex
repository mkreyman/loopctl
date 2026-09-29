defmodule Loopctl.Delivery.MergeExecutor do
  @moduledoc """
  loopctl merges a THREAD-mode story itself (US-45.5, Epic 45 PRD §4 items 3-5): it squashes
  the checkpoint the merge gate allowed onto the base branch as loopctl's GitHub App, by
  compare-and-swap. Run by `Loopctl.Workers.ThreadMergeWorker`, which
  `Loopctl.Delivery.MergePrecondition` enqueues when it records a thread-mode allow, and on a
  thread-mode `already_merged` verdict, whose adoption this module records.

  ## It trusts nothing the enqueue said

  The job carries only the story. Every run re-reads, before touching the forge: the stage row
  at `ci` with a `merge_gate_allowed_sha`; the claim placed in `thread` mode; the allow's own
  event naming a checkpoint (`Loopctl.Delivery.Stages.last_allow_query/2`) whose sha is that
  one; and the judged checkpoint (`Loopctl.Threads.claim_checkpoints/2`) being EXACTLY the
  allowed one. Only a state the executor does not apply to SKIPS: no story or stage row, not
  at `ci`, no allow, a pull-request claim, an allow for a checkpoint that is no longer the
  judged head. Anything else it cannot resolve at `ci` — an allow whose event names no
  checkpoint, a missing intake source, a branch it cannot name — ESCALATES naming the reason,
  because the gate authorised a merge that nothing would otherwise perform.

  ## The squash (AC-45.5.2)

  1. The base head. A `merge_commit_sha` recorded on the checkpoint, or the checkpoint's own
     commit, that the base CONTAINS is `:already_merged` (AC-45.5.3): the story moves to
     `merged` at it and nothing is written to the forge. That is the retry of a ref update
     whose acknowledgement was lost, and the adoption of a gate `already_merged`; the question
     it asks — is that commit an ancestor of the base — survives other merges landing in
     between, which a tree comparison would not.
  2. The checkpoint commit's tree, read from the forge. Not the recorded `tree_sha`:
     `tree_mismatch`, escalated, no write.
  3. FRESHNESS (AC-45.5.8): the base head must still be the allow's `base_sha`, the merge
     base the judged three-dot diff is relative to (which the checkpoint contains by
     definition).
     Otherwise the base-update path below: squashing the checkpoint's tree onto a newer base
     would silently revert every base commit the judged diff never saw.
  4. A checkpoint whose tree equals the base's is `empty_change`, escalated, never merged.
  5. The squash commit: the checkpoint's tree, the base head as its ONLY parent, the message
     of `Loopctl.Delivery.MergeMessage`. A commit recorded earlier with exactly that tree and
     parent is reused, so a retry converges on one commit.
  6. Its sha is RECORDED on the checkpoint (`Loopctl.Threads.record_merge_commit/6`), and that
     write is FENCED: under the story's and the stage row's locks the story must still be at
     `ci`, under the claim this run read, with the allow naming the checkpoint. A story
     released, moved or re-judged since the run began is never merged.
  7. The ref update, `force: false`. That is the compare-and-swap: GitHub refuses a move that
     is not a fast-forward, so a base that moved since step 1 cannot be overwritten, and the
     base-update path runs instead (AC-45.5.4).

  ## The base-update path (AC-45.5.4)

  1. The BOUND: one change is base-updated at most `max_consecutive_base_updates/0` times in a
     row, counted along its checkpoint's parents (`Loopctl.Threads.base_update_depth/3`).
     Freshness is exact equality on purpose, and in a repository whose base moves faster than
     one CI run that would update, wait for CI, find the base moved and update again for ever;
     at the bound it escalates `base_churn` with the count, for a human.
  2. The thread branch must still name the checkpoint, else `:base_moved`.
  3. A TEMPORARY branch `loop/loopctl-base-update-<story>-<random>` is created at the
     checkpoint and the App merges the base INTO it (`POST /repos/:repo/merges`). Merging into
     the thread branch by name would race the claimant's pushes between the read and the
     merge.
  4. The thread branch is moved to the merge commit with `force: false`: a fast-forward from
     the checkpoint, refused if anybody pushed in between — that refusal is `:base_moved`.
  5. Only then is the merge recorded as a `base_update` checkpoint, and the story stays at
     `ci` over `:base_updated`, in one transaction (`Loopctl.Threads.record_base_update/4`),
     keeping its review verdict and custody. The gate judges that head again, green CI on its
     exact sha included (AC-45.5.9). A conflict goes back to `implementing` over
     `:base_moved`, or escalates `claim_not_live` when nobody can fix it.
  6. The temporary branch is deleted, best effort. One left behind — a delete the forge
     refused, a ruleset on `loop/**` blocking deletion — is harmless: it names a commit that is
     also on the thread branch, nothing reads it, and a warning names it. Creating and merging
     into it is a push to `loop/**`, so a CI run may be spent on it; the gate trusts only runs
     a push of the THREAD branch triggered.

  ## Failure, retries and races (SOUL rule 9)

  - A TRANSIENT fault (`MergePrecondition.transient?/1`) is `{:retry, reason}`: the worker
    returns an error and Oban retries. On the worker's LAST attempt every outcome that is not
    resolved — a retry, a crash, an exit, an escalation that did not write — escalates
    `retries_exhausted` in ONE place (`run/3`), so no allowed story is left at `ci` after the
    job is discarded. A job killed outright, or lost to a redeploy, is re-driven by
    `Loopctl.Workers.ThreadMergeSweepWorker`.
  - Any other refusal escalates over `{:ci, :escalated, :merge_gate}`, naming the reason with
    a `merge_executor` prefix — `app_unconfigured` (the App's env unset), `tree_mismatch`,
    `empty_change`, `base_churn`, a ref update GitHub refused for another reason (a ruleset).
  - The ref update is an HTTP call and cannot run under the fence's lock, so a release can
    still land between step 6 and step 7. A merge that reached the base while the stage row
    does not hold it — the stage write after it failed, or a later run finds the recorded
    commit on the base with the story no longer at `ci` — ESCALATES naming the sha: over
    `:merge_gate` at `ci`, over `:merged_outside_ci` from `queued` or an in-flight stage. It
    is never skipped: the base holds a change the stage row does not.
  - A lost acknowledgement anywhere is answered by re-reading, never by remembering: a lost
    ref-update ack by step 1, a lost stage write by the same — a transient failure writing
    `merged` after the squash landed retries, and the retry adopts it.
  - ONE run per story at a time: the worker is unique while a job waits, runs or backs off.
    An allow the gate records during a run is therefore absorbed by that job, so every run
    ends by re-reading the allow and asks to run again (`{:rerun, _}`, a snooze) when the
    story is still at `ci` under an allow it did not begin with.
  - A base update whose thread-ref acknowledgement is lost, or whose record failed, has MOVED
    the thread branch with nothing recorded. The gate answers that head `base_update_in_flight`
    (a retry) while its first parent is the allowed checkpoint, and the executor's retry
    RECOGNISES its own merge — first parent the checkpoint, second on the base — and adopts it
    only after GitHub merges that same base commit into the checkpoint again and yields the
    identical tree. A merge commit anybody else pushed with another tree is a moved head.
  """

  require Logger

  alias Loopctl.Delivery.CheckpointSource
  alias Loopctl.Delivery.Claimant
  alias Loopctl.Delivery.DispatchPayload
  alias Loopctl.Delivery.MergeForge
  alias Loopctl.Delivery.MergeMessage
  alias Loopctl.Delivery.MergePrecondition
  alias Loopctl.Delivery.PullRequestSource
  alias Loopctl.Delivery.StageMachine
  alias Loopctl.Delivery.Stages
  alias Loopctl.Delivery.StoryStage
  alias Loopctl.Intake
  alias Loopctl.Repo
  alias Loopctl.Threads
  alias Loopctl.Threads.Checkpoint
  alias Loopctl.Verification.Credential
  alias Loopctl.WorkBreakdown.Stories

  @actor_label "control:merge_executor"

  # See the moduledoc's base-update path, step 1.
  @max_consecutive_base_updates 3

  # `merged` and every main-line stage after it: a row there carrying the sha HOLDS the merge.
  @merge_recorded_stages StageMachine.stages()
                         |> Enum.drop_while(&(&1 != :merged))
                         |> Enum.take_while(&(&1 not in [:escalated, :failed]))

  # Where a merge found outside `ci` escalates over `:merged_outside_ci` (at `ci`, `:merge_gate`).
  @orphan_edge_stages (StageMachine.in_flight_stages() -- [:ci]) ++ [:queued]

  @type outcome ::
          {:merged, String.t()}
          | {:already_merged, String.t()}
          | :base_updated
          | {:base_moved, term()}
          | {:escalated, term()}
          | {:skipped, term()}
          | {:retry, term()}

  @doc """
  One run for `story_id`. `final?` is true on the worker's last attempt: there, every outcome
  still asking for a retry escalates `retries_exhausted`, a crash included.
  """
  @spec run(Ecto.UUID.t(), Ecto.UUID.t(), boolean()) :: outcome() | {:rerun, outcome()}
  def run(tenant_id, story_id, final? \\ false) do
    before = allow_now(tenant_id, story_id)

    tenant_id
    |> guarded(story_id, final?)
    |> rerun_if_allow_moved(tenant_id, story_id, before)
  end

  # Every exit path of a run — a crash and an exit included — reaches `finalize/4`, which on
  # the last attempt escalates what is still unresolved. A brutal kill cannot be caught; the
  # sweeper (`Loopctl.Workers.ThreadMergeSweepWorker`) re-drives the story after one.
  defp guarded(tenant_id, story_id, final?) do
    tenant_id |> attempt(story_id, final?) |> finalize(tenant_id, story_id, final?)
  rescue
    error ->
      if final?,
        do: finalize({:retry, {:crashed, error.__struct__}}, tenant_id, story_id, true),
        else: reraise(error, __STACKTRACE__)
  catch
    :exit, reason ->
      if final?,
        do: finalize({:retry, {:exited, exit_shape(reason)}}, tenant_id, story_id, true),
        else: exit(reason)
  end

  defp exit_shape(reason) when is_tuple(reason), do: elem(reason, 0)
  defp exit_shape(reason) when is_atom(reason), do: reason
  defp exit_shape(_reason), do: :unreadable

  # ONE RUN PER STORY AT A TIME (the worker's uniqueness includes a running job), so an allow
  # the gate records WHILE this run executes is deduplicated into it and would be lost. So a
  # run ends by re-reading the allow: a story still at `ci` whose allow is not the one this
  # run began with is run again (`{:rerun, outcome}`, which the worker answers by snoozing
  # itself — a fresh enqueue from inside `perform` would be deduplicated into this very job).
  defp rerun_if_allow_moved(outcome, tenant_id, story_id, before) do
    case allow_now(tenant_id, story_id) do
      {:ci, sha} when is_binary(sha) and {:ci, sha} != before -> {:rerun, outcome}
      _unchanged -> outcome
    end
  end

  defp allow_now(tenant_id, story_id) do
    case Stages.get(tenant_id, story_id) do
      %StoryStage{stage: stage, merge_gate_allowed_sha: sha} -> {stage, sha}
      nil -> nil
    end
  rescue
    _error -> :unknown
  end

  @doc "The consecutive base updates of one change before the executor escalates `base_churn`."
  @spec max_consecutive_base_updates() :: pos_integer()
  def max_consecutive_base_updates, do: @max_consecutive_base_updates

  # THE ONE PLACE the last attempt is decided. Only `{:retry, _}` reaches here unresolved:
  # every other outcome already wrote what it means.
  defp finalize({:retry, reason}, tenant_id, story_id, true) do
    Logger.error(
      "merge_executor out of attempts, escalating: #{inspect(reason)} tenant_id=#{tenant_id} " <>
        "story_id=#{story_id}"
    )

    case Stories.get_story(tenant_id, story_id) do
      {:ok, story} -> last_attempt(%{tenant_id: tenant_id, story: story}, reason)
      {:error, _reason} -> {:skipped, {:retries_exhausted, reason}}
    end
  end

  defp finalize(outcome, _tenant_id, _story_id, _final?), do: outcome

  # The last attempt may have died AFTER the squash reached the base: an update whose answer
  # timed out, a crash between the ref update and `merged/2`. So it asks the orphan check's
  # question first — is the recorded squash on the base? — and adopts it (`ci -> merged`),
  # escalating naming the sha when that write fails. Only a squash NOT on the base, or one
  # that cannot be read, escalates `retries_exhausted`.
  defp last_attempt(base, reason) do
    with {:ok, sha} <- recorded_squash(base),
         {:ok, true} <- squash_on_base(base, sha) do
      case advance(base, {:ci, :merged, :forward}, effects: [merge_sha: sha]) do
        :ok -> {:merged, sha}
        {:error, error} -> orphan(base, sha, {:merged_not_recorded, error})
      end
    else
      _not_on_base_or_unreadable -> escalate(base, {:retries_exhausted, reason})
    end
  end

  defp attempt(tenant_id, story_id, final?) do
    case context(tenant_id, story_id) do
      {:ok, ctx} ->
        ctx |> Map.put(:final?, final?) |> execute() |> log(ctx)

      {:not_at_ci, base, row} ->
        orphan_check(base, row)

      {:escalate, base, reason} ->
        escalate(base, reason)

      {:skip, reason} ->
        Logger.info(
          "merge_executor merged nothing: #{inspect(reason)} tenant_id=#{tenant_id} " <>
            "story_id=#{story_id}"
        )

        {:skipped, reason}

      {:error, reason} ->
        {:retry, reason}
    end
  end

  # -- what the run is allowed to act on --------------------------------------------------

  defp context(tenant_id, story_id) do
    with {:ok, story} <- story(tenant_id, story_id),
         base = %{tenant_id: tenant_id, story: story},
         {:ok, stage} <- stage_at_ci(base),
         :ok <- allowed(stage) do
      resolve(base, stage)
    end
  end

  defp story(tenant_id, story_id) do
    case Stories.get_story(tenant_id, story_id) do
      {:ok, story} -> {:ok, story}
      {:error, :not_found} -> {:skip, :no_story}
    end
  end

  defp stage_at_ci(%{story: %{claim_epoch: epoch} = story} = base) do
    case Stages.get(base.tenant_id, story.id) do
      nil -> {:skip, :no_stage}
      %StoryStage{stage: :ci, claim_epoch: ^epoch} = row -> {:ok, row}
      %StoryStage{stage: :ci} -> {:skip, :stale_claim_epoch}
      %StoryStage{} = row -> {:not_at_ci, base, row}
    end
  end

  defp allowed(%StoryStage{merge_gate_allowed_sha: nil}), do: {:skip, :no_allow}
  defp allowed(%StoryStage{}), do: :ok

  # Past this point the story is at `ci` with an allow, so what cannot be resolved ESCALATES
  # (or retries, when it is transient): the gate authorised a merge nothing would perform.
  defp resolve(%{tenant_id: tenant_id, story: story} = base, stage) do
    with {:ok, route} <- DispatchPayload.dispatch_route(tenant_id, story),
         :ok <- thread_mode(route),
         {:ok, allow} <- recorded_allow(tenant_id, story.id, stage),
         {:ok, checkpoint} <- allowed_checkpoint(tenant_id, story.id, allow),
         {:ok, source} <- Intake.source_for_project(tenant_id, story.project_id),
         {:ok, branch} <- DispatchPayload.thread_branch(route, story, stage.branch) do
      {:ok,
       Map.merge(base, %{
         allow: allow,
         checkpoint: checkpoint,
         repo: source.repo_full_name,
         base_branch: DispatchPayload.placed_base_branch(route, source),
         branch: branch
       })}
    else
      {:skip, _reason} = skip -> skip
      {:error, reason} -> unresolved(base, reason)
    end
  end

  defp unresolved(base, reason) do
    if MergePrecondition.transient?(reason),
      do: {:error, reason},
      else: {:escalate, base, reason}
  end

  # #936: THE ONE WAY this module opens an App session. The App can read and write any
  # repository it is installed on, so every session — the squash, the base update, the
  # orphan check's reads — is licensed per (tenant, repository) first, here and nowhere else:
  #
  # - a pair the operator named in `VERIFICATION_OPERATOR_TOKEN_TENANTS` is the operator
  #   vouching for it;
  # - a tenant with its own token must be a principal that can push there itself
  #   (`push_permission/1`, asked WITH that token). That is GitHub's `permissions.push`, the
  #   token OWNER's role on the repository, and that is the question on purpose: the App
  #   writes, not the token, so what has to be established is that the tenant's principal
  #   controls the repository, never that the token it lent loopctl could write. A read-only
  #   token from a user with push rights licenses a merge that user could make themselves;
  # - anything else has no credential and no session.
  defp app_session(forge, tenant_id, repo) do
    with :ok <- write_licensed(tenant_id, repo), do: forge.session(repo)
  end

  defp write_licensed(tenant_id, repo) do
    case Credential.for_read(tenant_id, repo) do
      {:ok, %Credential{kind: :operator_token}} ->
        :ok

      {:ok, %Credential{kind: :tenant_token, repo: forge_repo}} ->
        case PullRequestSource.push_permission(forge_repo) do
          {:ok, true} -> :ok
          {:ok, false} -> {:error, :tenant_cannot_push}
          {:error, _reason} = error -> error
        end

      {:error, :credential_unavailable} = error ->
        error
    end
  end

  defp thread_mode(%{mode: :thread}), do: :ok
  defp thread_mode(_route), do: {:skip, :not_thread_mode}

  # The row's allow AND the event that recorded it, which names the checkpoint and the base.
  defp recorded_allow(tenant_id, story_id, %StoryStage{merge_gate_allowed_sha: sha}) do
    case Repo.with_tenant(tenant_id, fn ->
           Repo.one(Stages.last_allow_query(tenant_id, story_id))
         end) do
      {:ok, %{sha: ^sha, checkpoint_id: id, base_sha: base} = allow}
      when is_binary(id) and is_binary(base) ->
        {:ok, allow}

      {:ok, _other} ->
        {:error, :allow_names_no_checkpoint}

      {:error, _reason} = error ->
        error
    end
  end

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

    with {:ok, session} <- app_session(forge, ctx.tenant_id, ctx.repo),
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
        {:error, :not_fast_forward} -> update_base(ctx, base_head)
        {:error, reason} -> failed(ctx, reason)
      end
    else
      {:already_merged, sha} -> already(ctx, sha)
      :stale -> update_base(ctx, base_head)
      {:refuse, reason} -> escalate(ctx, reason)
      {:not_mergeable, reason} -> {:skipped, {:not_mergeable, reason}}
      {:error, reason} -> failed(ctx, reason)
    end
  end

  # The recorded squash, then the checkpoint's own commit (a fast-forward the gate adopted as
  # `already_merged` under its allow): whichever the base contains is the merge.
  defp already_merged(ctx, base_head) do
    [ctx.checkpoint.merge_commit_sha, ctx.checkpoint.commit_sha]
    |> Enum.reject(&is_nil/1)
    |> Enum.reduce_while(:continue, fn sha, :continue ->
      case ctx.forge.ancestor?(ctx.session, sha, base_head) do
        {:ok, true} -> {:halt, {:already_merged, sha}}
        {:ok, false} -> {:cont, :continue}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp tree_matches(%{tree_sha: tree}, %Checkpoint{tree_sha: tree}), do: :ok

  defp tree_matches(%{tree_sha: forge}, %Checkpoint{tree_sha: recorded}),
    do: {:refuse, {:tree_mismatch, forge, recorded}}

  # AC-45.5.8: the base head must be exactly the base the judged diff was relative to. No
  # ancestry check is needed beside it: `base_sha` is the gate's MERGE BASE of this checkpoint
  # and the base branch, so the checkpoint contains it by definition.
  defp fresh(%{allow: %{base_sha: base_head}}, base_head), do: :fresh
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

      {:error, _reason} = error ->
        error

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
      {:ok, _another_tree_or_base} -> :none
      {:error, {:github_api_error, 404}} -> :none
      # Unknown is not "unusable": the recorded squash may have landed, and a new one minted
      # over it would be a second commit for one change.
      {:error, _reason} = error -> error
    end
  end

  # The fence (moduledoc, squash step 6). A story that moved since this run read it is not
  # this run's to merge; one whose recorded commit another run replaced is not either.
  defp record_merge_commit(ctx, merge_sha) do
    %{tenant_id: tenant_id, story: story, checkpoint: checkpoint} = ctx

    case Threads.record_merge_commit(
           tenant_id,
           story.id,
           checkpoint.id,
           checkpoint.merge_commit_sha,
           merge_sha,
           story.claim_epoch
         ) do
      :ok -> :ok
      {:error, {:not_mergeable, reason}} -> {:not_mergeable, reason}
      # Another run's squash is recorded: not a human's problem. The next run adopts it
      # through `already_merged/2` once it is on the base, or replaces it by compare-and-set.
      {:error, {:merge_commit_moved, _stored}} -> {:not_mergeable, :merge_commit_moved}
      {:error, :busy} -> {:error, :busy}
      {:error, reason} -> {:error, {:merge_commit_not_recorded, reason}}
    end
  end

  # -- the base-update path -------------------------------------------------------------------

  defp update_base(ctx, base_head) do
    %{forge: forge, session: session, checkpoint: checkpoint} = ctx

    with :ok <- churn_bound(ctx),
         {:ok, head} <- forge.branch_head(session, ctx.branch),
         :ok <- branch_names_checkpoint(head, checkpoint),
         {:ok, outcome} <- with_temp(ctx, &merge_into_thread(ctx, &1)) do
      outcome
    else
      {:moved, {:thread_branch_moved, head}} -> recover_or_moved(ctx, head, base_head)
      {:refuse, reason} -> escalate(ctx, reason)
      {:error, reason} -> failed(ctx, reason)
    end
  end

  # A temporary branch at the checkpoint for `fun`, deleted afterwards whatever `fun` answered:
  # `{:ok, answer}`, or the error creating the branch.
  defp with_temp(ctx, fun) do
    temp = temp_branch(ctx.story)

    with :ok <- ctx.forge.create_ref(ctx.session, temp, ctx.checkpoint.commit_sha) do
      answer = fun.(temp)
      drop_temp(ctx, temp)
      {:ok, answer}
    end
  end

  # THIS EXECUTOR'S OWN BASE UPDATE, moved onto the thread branch by an earlier attempt that
  # died before recording it (a lost acknowledgement, a transient record failure). Recognised
  # only when the head's first parent is the allowed checkpoint and its second is on the base,
  # and CERTIFIED by asking GitHub to merge that same base commit into the checkpoint again on
  # a fresh temporary branch: only an identical tree is adopted. A merge commit anybody else
  # pushed with those parents but another tree is still a moved head.
  defp recover_or_moved(ctx, head, base_head) do
    sha = ctx.checkpoint.commit_sha

    with {:ok, %{tree_sha: tree} = commit} <- ctx.forge.commit(ctx.session, head),
         {:ok, second} <-
           CheckpointSource.base_update_of(
             commit,
             sha,
             &ctx.forge.ancestor?(ctx.session, &1, base_head)
           ),
         {:ok, {:ok, %{tree_sha: ^tree}}} <-
           with_temp(ctx, &ctx.forge.merge(ctx.session, &1, second, base_message(ctx))) do
      record_base_update(ctx, %{sha: head, tree_sha: tree})
    else
      # Not ours: not the executor's shape, another tree, or a base that no longer merges
      # cleanly into the checkpoint (the original merge was clean, so ours would re-merge).
      :no -> base_moved(ctx, {:thread_branch_moved, head})
      {:ok, {:ok, _another_tree_or_up_to_date}} -> base_moved(ctx, {:thread_branch_moved, head})
      {:ok, {:error, :merge_conflict}} -> base_moved(ctx, {:thread_branch_moved, head})
      # A forge that could not answer is not an answer: retried or escalated, as elsewhere.
      {:ok, {:error, reason}} -> failed(ctx, reason)
      {:error, reason} -> failed(ctx, reason)
    end
  end

  defp merge_into_thread(ctx, temp) do
    %{forge: forge, session: session} = ctx

    with {:ok, merged} <- forge.merge(session, temp, ctx.base_branch, base_message(ctx)),
         {:ok, commit} <- merged_onto_checkpoint(merged, ctx.checkpoint),
         :ok <- forge.update_ref(session, ctx.branch, commit.sha) do
      record_base_update(ctx, commit)
    else
      {:refuse, reason} -> escalate(ctx, reason)
      {:error, :merge_conflict} -> base_moved(ctx, :merge_conflict)
      # The claimant pushed between the read and this fast-forward.
      {:error, :not_fast_forward} -> base_moved(ctx, :thread_branch_moved)
      {:error, reason} -> failed(ctx, reason)
    end
  end

  defp churn_bound(ctx) do
    case Threads.base_update_depth(ctx.tenant_id, ctx.story.id, ctx.checkpoint.id) do
      {:ok, depth} when depth >= @max_consecutive_base_updates -> {:refuse, {:base_churn, depth}}
      {:ok, _depth} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp branch_names_checkpoint(sha, %Checkpoint{commit_sha: sha}), do: :ok
  defp branch_names_checkpoint(sha, _checkpoint), do: {:moved, {:thread_branch_moved, sha}}

  # AC-45.5.7: the merge must be GitHub's clean merge of the base into the allowed checkpoint.
  # The temporary branch was created AT the checkpoint, so any other first parent means
  # somebody wrote to it, and nothing of that commit is adopted.
  defp merged_onto_checkpoint(:up_to_date, _checkpoint),
    do: {:refuse, {:base_update_unexpected, :up_to_date}}

  defp merged_onto_checkpoint(%{parents: [parent | _]} = commit, %Checkpoint{commit_sha: parent}),
    do: {:ok, commit}

  defp merged_onto_checkpoint(%{parents: parents}, _checkpoint),
    do: {:refuse, {:base_update_unexpected, {:first_parent, List.first(parents)}}}

  defp record_base_update(ctx, commit) do
    case Threads.record_base_update(ctx.tenant_id, ctx.story.id, ctx.checkpoint.id,
           commit_sha: commit.sha,
           tree_sha: commit.tree_sha,
           actor_label: @actor_label
         ) do
      {:ok, _checkpoint, _status} ->
        :base_updated

      {:error, reason} when reason in [:stale_stage, :stale_claim_epoch, :allow_not_for_parent] ->
        # The story moved on while the base merged: the gate will see a branch head nobody
        # reported and decide. Nothing here may adopt it.
        {:skipped, {:base_update_not_recorded, reason}}

      # A transient failure retries, and the retry finds its own base update on the thread
      # branch and records it (`recover_or_moved/3`).

      {:error, reason} ->
        failed(ctx, reason)
    end
  end

  # A random suffix, so a retry never collides with a ref an earlier attempt left behind.
  defp temp_branch(story) do
    "loop/loopctl-base-update-#{String.slice(story.id, 0, 8)}-" <>
      Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
  end

  defp drop_temp(ctx, temp) do
    case ctx.forge.delete_ref(ctx.session, temp) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "merge_executor left a temporary branch behind: #{temp} reason=#{inspect(reason)} " <>
            "tenant_id=#{ctx.tenant_id} story_id=#{ctx.story.id}"
        )
    end
  end

  defp base_message(ctx) do
    "Merge #{ctx.base_branch} into #{ctx.branch} (loopctl base update)\n\n" <>
      "Loopctl-Story: #{ctx.story.id}"
  end

  # -- a merge the stage row does not hold ------------------------------------------------------

  # The story is not at `ci`. That is ordinary unless the checkpoint the gate last allowed has a
  # squash recorded that the base CONTAINS: then a merge landed that the row never recorded.
  defp orphan_check(base, row) do
    with {:ok, sha} <- recorded_squash(base),
         :unrecorded <- merged_row(row, sha),
         {:ok, true} <- squash_on_base(base, sha) do
      orphan(base, sha, :merged_outside_ci)
    else
      {:error, reason} -> unresolved_orphan(base, row, reason)
      _not_an_orphan -> {:skipped, {:not_at_ci, row.stage}}
    end
  end

  defp recorded_squash(%{tenant_id: tenant_id, story: story}) do
    tenant_id
    |> Repo.with_tenant(fn -> squash_of_last_allow(tenant_id, story.id) end)
    |> case do
      {:ok, answer} -> answer
      {:error, _reason} = error -> error
    end
  end

  defp squash_of_last_allow(tenant_id, story_id) do
    with %{checkpoint_id: id} when is_binary(id) <-
           Repo.one(Stages.last_allow_query(tenant_id, story_id)),
         %Checkpoint{merge_commit_sha: sha} when is_binary(sha) <-
           Threads.checkpoint_of(tenant_id, story_id, id) do
      {:ok, sha}
    else
      _none -> :none
    end
  end

  defp merged_row(%StoryStage{stage: stage, merge_sha: sha}, sha)
       when stage in @merge_recorded_stages,
       do: :recorded

  defp merged_row(_row, _sha), do: :unrecorded

  defp squash_on_base(%{tenant_id: tenant_id, story: story}, sha) do
    forge = MergeForge.impl()

    with {:ok, route} <- DispatchPayload.dispatch_route(tenant_id, story),
         {:ok, source} <- Intake.source_for_project(tenant_id, story.project_id),
         {:ok, session} <- app_session(forge, tenant_id, source.repo_full_name),
         {:ok, head} <-
           forge.branch_head(session, DispatchPayload.placed_base_branch(route, source)) do
      forge.ancestor?(session, sha, head)
    end
  end

  defp unresolved_orphan(base, row, reason) do
    if MergePrecondition.transient?(reason) do
      {:retry, reason}
    else
      Logger.warning(
        "merge_executor could not check for a merge outside ci: #{inspect(reason)} " <>
          "tenant_id=#{base.tenant_id} story_id=#{base.story.id}"
      )

      {:skipped, {:not_at_ci, row.stage}}
    end
  end

  # A merge on the base the stage row does not hold. Escalated from wherever the story is now,
  # under its CURRENT claim, naming the sha — never skipped.
  defp orphan(%{tenant_id: tenant_id, story: story}, sha, why) do
    now = %{tenant_id: tenant_id, story: current(tenant_id, story)}

    case Stages.get(tenant_id, story.id) do
      %StoryStage{stage: stage, merge_sha: ^sha} when stage in @merge_recorded_stages ->
        {:merged, sha}

      _unrecorded ->
        escalate(now, {why, sha}, sha)
    end
  end

  defp current(tenant_id, story) do
    case Stories.get_story(tenant_id, story.id) do
      {:ok, story} -> story
      {:error, :not_found} -> story
    end
  end

  # -- outcomes --------------------------------------------------------------------------------

  # The squash is on the base. A TRANSIENT failure to record that retries — the next run finds
  # the recorded commit on the base (`already_merged/2`) and records it — unless this is the
  # last attempt; anything else escalates naming the sha, from wherever the story is.
  defp merged(ctx, sha) do
    case advance(ctx, {:ci, :merged, :forward}, effects: [merge_sha: sha]) do
      :ok ->
        {:merged, sha}

      {:error, reason} ->
        if MergePrecondition.transient?(reason) and not ctx.final?,
          do: {:retry, {:merged_not_recorded, sha, reason}},
          else: orphan(ctx, sha, {:merged_not_recorded, reason})
    end
  end

  defp already(ctx, sha) do
    case merged(ctx, sha) do
      {:merged, ^sha} -> {:already_merged, sha}
      other -> other
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
    if MergePrecondition.transient?(reason),
      do: {:retry, reason},
      else: escalate(ctx, reason)
  end

  # THE ONE ESCALATION, its edge chosen from where the story IS now: `merge_gate` at `ci`, and
  # — for a merge on the base the row does not hold (`merged_sha`) — `merged_outside_ci` from
  # `queued` or an in-flight stage. Anywhere else there is no edge to write, so it is logged
  # at error for a human and answered `{:skipped, _}`.
  defp escalate(ctx, reason, merged_sha \\ nil) do
    case Stages.get(ctx.tenant_id, ctx.story.id) do
      %StoryStage{stage: :ci} ->
        escalate_over(ctx, {:ci, :escalated, :merge_gate}, reason)

      %StoryStage{stage: stage} when is_binary(merged_sha) and stage in @orphan_edge_stages ->
        escalate_over(ctx, {stage, :escalated, :merged_outside_ci}, reason)

      row ->
        stage = row && row.stage

        Logger.error(
          "merge_executor cannot escalate from #{inspect(stage)}: #{inspect(reason)}; a human " <>
            "must reconcile it tenant_id=#{ctx.tenant_id} story_id=#{ctx.story.id}"
        )

        {:skipped, {reason, stage}}
    end
  end

  defp escalate_over(ctx, transition, reason) do
    case advance(ctx, transition, reason: reason_text(reason)) do
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

  defp reason_text(reason), do: StageMachine.bounded_reason("merge_executor: " <> inspect(reason))

  defp thread_url(story), do: LoopctlWeb.Endpoint.url() <> "/api/v1/stories/#{story.id}/thread"

  defp log(outcome, ctx) do
    Logger.info(
      "merge_executor #{inspect(outcome)} tenant_id=#{ctx.tenant_id} story_id=#{ctx.story.id}"
    )

    outcome
  end
end
