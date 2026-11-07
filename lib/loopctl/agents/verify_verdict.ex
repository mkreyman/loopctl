defmodule Loopctl.Agents.VerifyVerdict do
  @moduledoc """
  Applies a `verify@1` verdict (US-48.18): control reports, reviews and verifies the story on a
  `pass`, or sends it back to work on a `reject`, under the verifier dispatch B that
  `Loopctl.Agents.VerifierPlacement` minted.

  ## Where the verdict lives, and how it reaches the job

  The verdict is recorded ONCE on B's dispatch ledger row (`agent_result`, spec `verify@1`) by
  `Loopctl.Agents.AgentResult`, and that row is the only copy: the job carries ids, never the
  verdict, and reads it back from the ledger. `enqueue/1` inserts a
  `Loopctl.Workers.VerifyVerdictWorker` job, unique per `(story_id, dispatch_id)` over every
  state, AFTER the ledger transaction commits — `oban_jobs` is not readable under the ledger's
  RLS role, and the custody writes the job makes run on `AdminRepo`, which a `Repo`
  transaction must never hold open. A node dying between the commit and the insert loses
  nothing: `enqueue_unapplied/1`, run every minute by `Loopctl.Workers.VerifyDispatchWorker`,
  enqueues every recorded verdict whose B is still live and still bound — and every outcome of
  `apply/1` revokes B, so "live and bound" is exactly "not yet applied". The runner's resend of
  the same verdict (a replay) enqueues too; uniqueness makes all three one job.

  ## What `apply/1` checks first, and drops on

  Every refusal here writes a `verify_verdict_dropped` audit row and revokes B; nothing moves.

  - **The binding**: the story's `verifier_dispatch_id` is the verdict's dispatch, that dispatch
    is B for THIS story, it is live, and its agent is the agent of the runner that answered.
    (`:verifier_not_bound`)
  - **The head** (`:verdict_stale`): the story is at `ci` and its recorded head is the head the
    verdict judged. A verdict for a head the story has moved past says nothing about the new one.

  ## `pass`

  Each step is skipped when already done, so a retried job resumes where it stopped:

  1. `ImplementerStart.ensure_started/3` (a story claimed before its start was spent);
  2. `Progress.report_story/4` unless the story is `reported_done`;
  3. `Progress.record_review/4` unless a review of THIS report (`reviewed_report_at` equal to
     its `reported_done_at`) exists;
  4. `Progress.verify_story/4` unless the story is verified;

  all three as B: `agent_id` is B's `agent_id` and the lineage is B's `lineage_path`, both read
  off the dispatch row control minted, never off the runner's message. Then the stage effect
  `verified_head_sha`, written under the row lock with a guard that the head is still the
  judged one; if the head moved, the verification is invalidated rather than left standing on a
  head nobody judged. Then B is revoked.

  `Progress.bind_verifier_dispatch/4` retired any earlier report and verification when B was
  bound, and on the pull-request route `Progress` refuses report, review-complete and verify
  to every key but B's (`pr_route_verifier_only`), so "already done" can only mean done by THIS
  verdict's earlier attempt. The skips check it anyway: a report or review found done under
  another agent is `{:error, :custody_act_by_other}`, never a skip.

  ## `reject`

  `{:ci, :implementing, :verify_rejected}`, the findings as its reason, with a row guard that
  the head is still the judged one. Then B is revoked.

  ## Failures

  A refusal that clears by itself (`@retryable`) returns `{:error, reason}` and Oban retries.
  Anything else — a custody refusal above all — is cancelled, logged and recorded, and B is
  revoked; the story is a `verify@1` candidate again on the next pass.
  """

  require Logger

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.Artifacts.ReviewRecord
  alias Loopctl.Audit
  alias Loopctl.Delivery.ImplementerStart
  alias Loopctl.Delivery.Stages
  alias Loopctl.Delivery.StoryStage
  alias Loopctl.Dispatches
  alias Loopctl.Dispatches.Dispatch
  alias Loopctl.Progress
  alias Loopctl.Repo
  alias Loopctl.Runners
  alias Loopctl.Runners.DispatchLedger
  alias Loopctl.Runners.DispatchRecord
  alias Loopctl.Tenants
  alias Loopctl.WorkBreakdown.Story
  alias Loopctl.Workers.VerifyVerdictWorker

  @actor_label "control:verify_verdict"
  @retryable [:busy, :capacity_busy, :capability_mint_failed, :audit_chain_append_failed]

  @doc """
  Inserts the job that applies the verdict recorded on `record` (B's ledger row). Call it after
  the ledger transaction has committed. Unique per `(story_id, dispatch_id)`, so a second call —
  a replay, the sweep — inserts nothing. A failed insert is logged and left to the sweep.
  """
  @spec enqueue(DispatchRecord.t()) :: :ok
  def enqueue(%DispatchRecord{} = record) do
    case %{
           "tenant_id" => record.tenant_id,
           "story_id" => record.story_id,
           "dispatch_id" => record.dispatch_id
         }
         |> VerifyVerdictWorker.new()
         |> Oban.insert() do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "verify verdict job not enqueued; the minute sweep enqueues it: " <>
            "tenant_id=#{record.tenant_id} dispatch_id=#{record.dispatch_id} " <>
            "reason=#{inspect(reason)}",
          tenant_id: record.tenant_id
        )
    end
  rescue
    error ->
      Logger.warning(
        "verify verdict job not enqueued; the minute sweep enqueues it: " <>
          "dispatch_id=#{record.dispatch_id} error=#{Exception.message(error)}"
      )
  end

  @doc """
  Enqueues the job for every recorded `verify@1` verdict not yet applied — its ledger row holds
  a result, and the story still names its dispatch as a live verifier dispatch — at most
  `limit` of them, oldest first. Returns how many it asked for; uniqueness drops the rest.
  """
  @spec enqueue_unapplied(pos_integer()) :: non_neg_integer()
  def enqueue_unapplied(limit) when is_integer(limit) and limit > 0 do
    rows =
      AdminRepo.all(
        from r in DispatchRecord,
          join: s in Story,
          on: s.tenant_id == r.tenant_id and s.id == r.story_id,
          join: d in Dispatch,
          on: d.tenant_id == r.tenant_id and d.id == r.dispatch_id,
          where: r.kind == "verify" and r.agent_result_spec == "verify@1",
          where: not is_nil(r.agent_result_digest),
          where: s.verifier_dispatch_id == r.dispatch_id and is_nil(d.revoked_at),
          where: d.expires_at > ^DateTime.utc_now(),
          order_by: [asc: r.agent_result_at],
          limit: ^limit
      )

    Enum.each(rows, &enqueue/1)
    length(rows)
  end

  @type args :: %{required(String.t()) => term()}

  @doc "Applies one verdict. See the moduledoc."
  @spec apply(args()) ::
          {:ok, :verified | :rejected | :dropped}
          | {:error, term()}
          | {:cancel, term()}
          | {:snooze, pos_integer()}
  def apply(%{"tenant_id" => tenant_id, "story_id" => story_id, "dispatch_id" => dispatch_id}) do
    # The custody surface is frozen by a halt and closed to a tenant that is not human-anchored,
    # and this job reaches report, review-complete and verify with no plug in front of it — the
    # same routeless shape as `Placement` and `VerifierPlacement`, gated the same way. Checked
    # FIRST, before anything is read or dropped: a halt is a human's to clear, so the verdict
    # waits (`{:snooze, _}`) rather than spending its attempts.
    with :ok <- custody_open(tenant_id),
         {:ok, verdict} <- recorded_verdict(tenant_id, story_id, dispatch_id),
         {:ok, story} <- fetch_story(tenant_id, story_id),
         :pending <- already_applied(tenant_id, story, dispatch_id, verdict),
         {:ok, verifier} <- bound_verifier(tenant_id, story, dispatch_id, verdict["runner_id"]),
         {:ok, stage} <- judged_head(tenant_id, story_id, verdict["head_sha"]) do
      run(verdict["verdict"], tenant_id, story, verifier, stage, verdict)
    else
      {:already, outcome} ->
        {:ok, outcome}

      {:drop, reason} ->
        drop(tenant_id, story_id, dispatch_id, reason)

      {:snooze, _seconds} = snooze ->
        snooze

      {:cancel, _reason} = cancel ->
        cancel

      {:error, reason} when reason in [:story_not_found, :no_recorded_verdict] ->
        {:cancel, reason}
    end
  end

  @halt_snooze_seconds 300

  defp custody_open(tenant_id) do
    cond do
      Runners.custody_halted?(tenant_id) -> {:snooze, @halt_snooze_seconds}
      Tenants.require_human_anchor(tenant_id) != :ok -> {:cancel, :custody_tier_required}
      true -> :ok
    end
  end

  # The verdict as the ledger recorded it — the schema-validated result, on the row of the
  # dispatch the job names, in its tenant, for its story. The runner is the row's, never an
  # argument.
  defp recorded_verdict(tenant_id, story_id, dispatch_id) do
    case DispatchLedger.get_record(tenant_id, dispatch_id) do
      %DispatchRecord{
        kind: "verify",
        agent_result_spec: "verify@1",
        story_id: ^story_id,
        agent_result: %{} = result
      } = record ->
        {:ok,
         %{
           "runner_id" => record.runner_id,
           "verdict" => field(result, "verdict"),
           "head_sha" => field(result, "head_sha"),
           "findings" => field(result, "findings") || []
         }}

      _ ->
        {:error, :no_recorded_verdict}
    end
  end

  # A row read back from Postgres has string keys; the struct `record_agent_result/5` returns
  # still holds the atom-keyed map it was given.
  defp field(result, key),
    do: Map.get(result, key) || Map.get(result, String.to_existing_atom(key))

  # A job re-run after it finished (a node died between the last write and the ack): the
  # verification its dispatch made is recorded at the head it judged, so there is nothing to
  # do — and B, already revoked, would otherwise read as a binding to drop.
  defp already_applied(
         tenant_id,
         %Story{verifier_dispatch_id: dispatch_id} = story,
         dispatch_id,
         args
       ) do
    judged = args["head_sha"]

    case Stages.get(tenant_id, story.id) do
      %StoryStage{verified_head_sha: ^judged} when is_binary(judged) ->
        if story.verified_status == :verified, do: {:already, :verified}, else: :pending

      _ ->
        :pending
    end
  end

  defp already_applied(_tenant_id, _story, _dispatch_id, _args), do: :pending

  # ── the checks ──────────────────────────────────────────────────────────────────────────────

  defp fetch_story(tenant_id, story_id) do
    case AdminRepo.get_by(Story, id: story_id, tenant_id: tenant_id) do
      nil -> {:error, :story_not_found}
      story -> {:ok, story}
    end
  end

  # B, as control minted and bound it. Custody identity is read here and only here: the
  # dispatch row's agent and lineage, checked against the story's binding and the runner that
  # answered, never against anything in the verdict.
  defp bound_verifier(tenant_id, %Story{verifier_dispatch_id: id} = story, id, runner_id)
       when is_binary(id) do
    now = DateTime.utc_now()

    with {:ok, %Dispatch{} = b} <- Dispatches.get_dispatch(tenant_id, id),
         true <- b.story_id == story.id,
         true <- is_nil(b.revoked_at) and DateTime.compare(b.expires_at, now) == :gt,
         [_ | _] <- b.lineage_path,
         true <- is_binary(b.agent_id),
         {:ok, runner} <- Runners.get_runner(tenant_id, runner_id),
         true <- runner.agent_id == b.agent_id do
      {:ok, b}
    else
      _ -> {:drop, :verifier_not_bound}
    end
  end

  defp bound_verifier(_tenant_id, _story, _dispatch_id, _runner_id),
    do: {:drop, :verifier_not_bound}

  defp judged_head(tenant_id, story_id, head) do
    case Stages.get(tenant_id, story_id) do
      %StoryStage{stage: :ci, head_sha: ^head} = row when is_binary(head) -> {:ok, row}
      _ -> {:drop, :verdict_stale}
    end
  end

  # ── pass ────────────────────────────────────────────────────────────────────────────────────

  defp run("pass", tenant_id, story, verifier, stage, args) do
    with {:ok, _} <-
           ImplementerStart.ensure_started(tenant_id, story.id, actor_label: @actor_label),
         :ok <- report(tenant_id, story.id, verifier),
         :ok <- review(tenant_id, story.id, verifier, args),
         :ok <- verify(tenant_id, story.id, verifier, stage),
         :ok <- record_verified_head(tenant_id, story.id, stage, verifier.id) do
      revoke(tenant_id, verifier)
      {:ok, :verified}
    else
      {:error, reason} -> fail(tenant_id, story.id, verifier, reason)
    end
  end

  defp run("reject", tenant_id, story, verifier, stage, args) do
    head = stage.head_sha

    case Stages.advance(tenant_id, story.id, {:ci, :implementing, :verify_rejected},
           claim_epoch: story.claim_epoch,
           reason: rejection_reason(args["findings"]),
           actor_label: @actor_label,
           actor_role: :agent,
           actor_lineage: [],
           row_guard: fn row ->
             if row.head_sha == head, do: :ok, else: {:error, :verdict_stale}
           end
         ) do
      {:ok, _row} ->
        revoke(tenant_id, verifier)
        {:ok, :rejected}

      {:error, reason} when reason in [:verdict_stale, :stale_stage, :stale_claim_epoch] ->
        drop(tenant_id, story.id, verifier.id, :verdict_stale)

      {:error, reason} ->
        fail(tenant_id, story.id, verifier, reason)
    end
  end

  defp report(tenant_id, story_id, verifier) do
    case fetch_story(tenant_id, story_id) do
      {:ok, %Story{agent_status: :reported_done, reported_by_agent_id: by}} ->
        if by == verifier.agent_id, do: :ok, else: {:error, :custody_act_by_other}

      {:ok, %Story{} = story} ->
        tenant_id
        |> Progress.report_story(story_id,
          agent_id: verifier.agent_id,
          reporter_lineage: verifier.lineage_path,
          claim_epoch: story.claim_epoch,
          actor_label: @actor_label
        )
        |> ok()

      error ->
        error
    end
  end

  defp review(tenant_id, story_id, verifier, args) do
    {:ok, story} = fetch_story(tenant_id, story_id)

    case reviewers(tenant_id, story) do
      [] ->
        record_review(tenant_id, story_id, verifier, args)

      reviewers ->
        if verifier.agent_id in reviewers, do: :ok, else: {:error, :custody_act_by_other}
    end
  end

  defp record_review(tenant_id, story_id, verifier, args) do
    tenant_id
    |> Progress.record_review(
      story_id,
      %{
        "review_type" => "verify@1",
        "findings_count" => length(args["findings"] || []),
        "summary" => "verify@1 pass at #{args["head_sha"]}"
      },
      reviewer_agent_id: verifier.agent_id,
      reviewer_lineage: verifier.lineage_path,
      actor_label: @actor_label
    )
    |> ok()
  end

  # The reviewers of THIS report: records whose `reviewed_report_at` is the story's current
  # `reported_done_at`.
  defp reviewers(tenant_id, %Story{reported_done_at: %DateTime{} = at, id: story_id}) do
    AdminRepo.all(
      from r in ReviewRecord,
        where: r.tenant_id == ^tenant_id and r.story_id == ^story_id,
        where: r.reviewed_report_at == ^at,
        select: r.reviewer_agent_id
    )
  end

  defp reviewers(_tenant_id, _story), do: []

  defp verify(tenant_id, story_id, verifier, stage) do
    case fetch_story(tenant_id, story_id) do
      {:ok, %Story{verified_status: :verified}} ->
        :ok

      {:ok, _story} ->
        tenant_id
        |> Progress.verify_story(
          story_id,
          %{"summary" => "verify@1 pass at #{stage.head_sha}", "review_type" => "verify@1"},
          orchestrator_agent_id: verifier.agent_id,
          verifier_lineage: verifier.lineage_path,
          actor_label: @actor_label
        )
        |> ok()

      error ->
        error
    end
  end

  @doc """
  The last write of a `pass`: records `verified_head_sha` as `stage.head_sha` — the head the
  verdict judged, as `apply/1` read it — under the row lock, on the guard that the row's head
  is STILL that one AND that the story is still `verified` under `verifier_dispatch_id`. A head
  that moved in between leaves a verification of nothing anyone judged, so it is retired
  (`Progress.invalidate_verification/3`) rather than kept, and the answer is
  `{:error, {:verified_head_not_recorded, reason}}`. A story that a later verifier dispatch
  was bound to in between (B expired mid-apply and B2 was placed, which retired this
  verification) is `:verifier_rebound`: writing the head then would leave `verified_head_sha`
  equal to the head on an UNVERIFIED story, which takes it out of verify@1's candidates for
  good.

  Public so a test can hand it the row `apply/1` read, which is the only way to reach the race
  it guards without racing two processes.
  """
  @spec record_verified_head(Ecto.UUID.t(), Ecto.UUID.t(), StoryStage.t(), Ecto.UUID.t()) ::
          :ok | {:error, {:verified_head_not_recorded, term()}}
  def record_verified_head(
        tenant_id,
        story_id,
        %StoryStage{head_sha: head} = stage,
        verifier_dispatch_id
      ) do
    case Stages.record_effect(tenant_id, story_id, :verified_head_sha, head,
           claim_epoch: stage.claim_epoch,
           actor_label: @actor_label,
           guard: fn ->
             with :ok <- head_still(tenant_id, story_id, head) do
               still_verified_by(tenant_id, story_id, verifier_dispatch_id)
             end
           end
         ) do
      {:ok, _row} ->
        :ok

      # The rebind already retired this verification; retiring again could only reach the
      # NEW verifier's, should it have finished in between.
      {:error, :verifier_rebound} ->
        {:error, {:verified_head_not_recorded, :verifier_rebound}}

      {:error, reason} ->
        retire(tenant_id, story_id, reason)
        {:error, {:verified_head_not_recorded, reason}}
    end
  end

  # Read inside `record_effect/5`'s transaction, which already holds the row lock.
  defp head_still(tenant_id, story_id, head) do
    current =
      Repo.one(
        from s in StoryStage,
          where: s.tenant_id == ^tenant_id and s.story_id == ^story_id,
          select: s.head_sha
      )

    if current == head, do: :ok, else: {:error, :verdict_stale}
  end

  # Read under the stage-row lock `record_effect/5` holds, and deliberately WITHOUT a story
  # lock (`Progress.bind_verifier_dispatch/4` locks story, then stage; locking story here would
  # invert that order). Either the rebind committed first and this sees it, or the rebind's
  # retirement runs after this commit and clears `verified_head_sha` itself, in its own
  # transaction, behind the stage-row lock it then waits for.
  defp still_verified_by(tenant_id, story_id, verifier_dispatch_id) do
    current =
      Repo.one(
        from s in Story,
          where: s.tenant_id == ^tenant_id and s.id == ^story_id,
          select: {s.verified_status, s.verifier_dispatch_id}
      )

    case current do
      {:verified, ^verifier_dispatch_id} -> :ok
      _ -> {:error, :verifier_rebound}
    end
  end

  defp retire(tenant_id, story_id, cause) do
    case Progress.retire_verification(tenant_id, story_id,
           cause: "verified_head_not_recorded",
           actor_label: @actor_label
         ) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error(
          "verification NOT retired after its head moved; the merge gate still refuses it " <>
            "(verified_head_sha is unset): tenant_id=#{tenant_id} story_id=#{story_id} " <>
            "cause=#{inspect(cause)} reason=#{inspect(reason)}",
          tenant_id: tenant_id
        )
    end
  end

  defp rejection_reason([_ | _] = findings),
    do: "verify@1 rejected the head: " <> Enum.join(findings, "; ")

  defp rejection_reason(_none), do: "verify@1 rejected the head and named no finding"

  defp ok({:ok, _}), do: :ok
  defp ok({:error, reason}), do: {:error, reason}
  defp ok({:error, reason, _detail}), do: {:error, reason}

  # ── failures, drops, the revoke ─────────────────────────────────────────────────────────────

  defp fail(_tenant_id, _story_id, _verifier, reason) when reason in @retryable,
    do: {:error, reason}

  defp fail(tenant_id, story_id, verifier, reason) do
    Logger.error(
      "verify@1 verdict NOT applied; the story is a verify candidate again on the next pass: " <>
        "tenant_id=#{tenant_id} story_id=#{story_id} dispatch_id=#{verifier.id} " <>
        "reason=#{inspect(reason)}",
      tenant_id: tenant_id
    )

    record(tenant_id, story_id, verifier.id, "verify_verdict_failed", reason)
    revoke(tenant_id, verifier)
    {:cancel, reason}
  end

  defp drop(tenant_id, story_id, dispatch_id, reason) do
    Logger.info(
      "verify@1 verdict dropped: tenant_id=#{tenant_id} story_id=#{story_id} " <>
        "dispatch_id=#{dispatch_id} reason=#{reason}",
      tenant_id: tenant_id
    )

    record(tenant_id, story_id, dispatch_id, "verify_verdict_dropped", reason)
    revoke_if_ours(tenant_id, story_id, dispatch_id)
    {:ok, :dropped}
  end

  # A dropped verdict's dispatch is revoked only when it is a verifier dispatch of THIS story:
  # a mismatched binding names a dispatch control may not have minted for it.
  defp revoke_if_ours(tenant_id, story_id, dispatch_id) do
    case Dispatches.get_dispatch(tenant_id, dispatch_id) do
      {:ok, %Dispatch{story_id: ^story_id, parent_dispatch_id: nil, role: :orchestrator} = b} ->
        revoke(tenant_id, b)

      _ ->
        :ok
    end
  end

  defp record(tenant_id, story_id, dispatch_id, action, reason) do
    case Audit.create_log_entry(tenant_id, %{
           entity_type: "story",
           entity_id: story_id,
           action: action,
           actor_type: "system",
           actor_label: @actor_label,
           metadata: %{"dispatch_id" => dispatch_id, "reason" => inspect(reason)}
         }) do
      {:ok, _} ->
        :ok

      {:error, error} ->
        Logger.error(
          "#{action} with NO audit row: story_id=#{story_id} error=#{inspect(error)}",
          tenant_id: tenant_id
        )
    end
  end

  defp revoke(tenant_id, %Dispatch{id: id}) do
    case Dispatches.revoke(tenant_id, id, actor_lineage: []) do
      {:ok, _} ->
        :ok

      other ->
        Logger.error(
          "verifier dispatch not revoked; its key holds its agent's :orchestrator slot until " <>
            "it expires. Revoke it (MCP revoke_dispatch): tenant_id=#{tenant_id} " <>
            "dispatch_id=#{id} outcome=#{inspect(other)}",
          tenant_id: tenant_id
        )
    end
  end
end
