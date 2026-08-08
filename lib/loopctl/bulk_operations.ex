defmodule Loopctl.BulkOperations do
  @moduledoc """
  Context module for bulk story operations.

  Supports partial-success semantics where each story in a batch is processed
  independently. Stories that fail precondition checks are skipped (not
  rolled back). Stories that succeed are committed.

  Lock ordering: stories are always locked BY id ASC to prevent deadlocks
  between concurrent bulk operations.

  ## Supported operations

  - `bulk_claim/4` -- agent claims multiple pending stories
  - `bulk_verify/4` -- orchestrator verifies multiple reported_done stories
  - `bulk_reject/4` -- orchestrator rejects multiple reported_done stories
  """

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.Artifacts.VerificationResult
  alias Loopctl.Audit
  alias Loopctl.Dispatches
  alias Loopctl.Progress
  alias Loopctl.Webhooks.EventGenerator
  alias Loopctl.Webhooks.WebhookEvent
  alias Loopctl.WorkBreakdown.Story
  alias Loopctl.Workers.WebhookDeliveryWorker

  @max_batch_size 50

  # ===================================================================
  # Bulk Claim (US-13.1)
  # ===================================================================

  @doc """
  Claims multiple stories for an agent.

  Each story is processed independently. Stories must be in `contracted` status
  (matching individual claim_story) with all dependencies satisfied.

  ## Parameters

  - `tenant_id` -- the tenant UUID
  - `story_ids` -- list of story UUIDs to claim
  - `agent_id` -- the claiming agent's UUID
  - `opts` -- keyword list with `:actor_id`, `:actor_label`

  ## Returns

  - `{:ok, results}` -- list of per-story results
  - `{:error, :batch_too_large}` -- if batch exceeds max size
  - `{:error, :empty_batch}` -- if story_ids is empty
  """
  @spec bulk_claim(Ecto.UUID.t(), [Ecto.UUID.t()], Ecto.UUID.t(), keyword()) ::
          {:ok, [map()]} | {:error, atom()}
  def bulk_claim(tenant_id, story_ids, agent_id, opts \\ []) do
    with :ok <- validate_batch_size(story_ids) do
      actor_id = Keyword.get(opts, :actor_id)
      actor_label = Keyword.get(opts, :actor_label)
      sorted_ids = Enum.sort(story_ids)

      AdminRepo.transaction(fn ->
        locked_stories = lock_stories_by_ids(tenant_id, sorted_ids)
        process_claims(sorted_ids, locked_stories, agent_id, tenant_id, actor_id, actor_label)
      end)
    end
  end

  # ===================================================================
  # Bulk Verify (US-13.1)
  # ===================================================================

  @doc """
  Verifies multiple stories as an orchestrator.

  Each story entry must include `story_id`, `result`, and `summary`.

  ## Parameters

  - `tenant_id` -- the tenant UUID
  - `stories` -- list of maps with `"story_id"`, `"result"`, `"summary"`, optional `"findings"`
  - `orchestrator_agent_id` -- the orchestrator's agent UUID
  - `opts` -- keyword list with `:actor_id`, `:actor_label`

  ## Returns

  - `{:ok, results}` -- list of per-story results
  """
  @spec bulk_verify(Ecto.UUID.t(), [map()], Ecto.UUID.t() | nil, keyword()) ::
          {:ok, [map()]} | {:error, atom()}
  def bulk_verify(tenant_id, stories, orchestrator_agent_id, opts \\ []) do
    story_ids = Enum.map(stories, &(&1["story_id"] || &1[:story_id]))

    with :ok <- validate_batch_size(story_ids) do
      actor_id = Keyword.get(opts, :actor_id)
      actor_label = Keyword.get(opts, :actor_label)

      story_params =
        Map.new(stories, fn s ->
          sid = s["story_id"] || s[:story_id]
          {sid, s}
        end)

      sorted_ids = Enum.sort(story_ids)

      ctx = %{
        tenant_id: tenant_id,
        orch_id: orchestrator_agent_id,
        actor_id: actor_id,
        actor_label: actor_label,
        caller_lineage: caller_lineage(tenant_id, opts)
      }

      AdminRepo.transaction(fn ->
        locked_stories = lock_stories_by_ids(tenant_id, sorted_ids)
        process_verifications(sorted_ids, locked_stories, story_params, ctx)
      end)
    end
  end

  # ===================================================================
  # Bulk Reject (US-13.1)
  # ===================================================================

  @doc """
  Rejects multiple stories as an orchestrator.

  Each story entry must include `story_id` and a non-empty `reason`.

  ## Parameters

  - `tenant_id` -- the tenant UUID
  - `stories` -- list of maps with `"story_id"`, `"reason"`, optional `"findings"`
  - `orchestrator_agent_id` -- the orchestrator's agent UUID
  - `opts` -- keyword list with `:actor_id`, `:actor_label`

  ## Returns

  - `{:ok, results}` -- list of per-story results
  """
  @spec bulk_reject(Ecto.UUID.t(), [map()], Ecto.UUID.t() | nil, keyword()) ::
          {:ok, [map()]} | {:error, atom()}
  def bulk_reject(tenant_id, stories, orchestrator_agent_id, opts \\ []) do
    story_ids = Enum.map(stories, &(&1["story_id"] || &1[:story_id]))

    with :ok <- validate_batch_size(story_ids) do
      actor_id = Keyword.get(opts, :actor_id)
      actor_label = Keyword.get(opts, :actor_label)

      story_params =
        Map.new(stories, fn s ->
          sid = s["story_id"] || s[:story_id]
          {sid, s}
        end)

      sorted_ids = Enum.sort(story_ids)

      ctx = %{
        tenant_id: tenant_id,
        orch_id: orchestrator_agent_id,
        actor_id: actor_id,
        actor_label: actor_label,
        caller_lineage: caller_lineage(tenant_id, opts)
      }

      AdminRepo.transaction(fn ->
        locked_stories = lock_stories_by_ids(tenant_id, sorted_ids)
        process_rejections(sorted_ids, locked_stories, story_params, ctx)
      end)
    end
  end

  # ===================================================================
  # Bulk Mark Complete (API Discoverability Issue 5)
  # ===================================================================

  @doc """
  Marks multiple stories as completed in one step (admin operation).

  Sets both `agent_status` to `reported_done` AND `verified_status` to `verified`
  atomically. Intended for marking pre-existing work — skips the normal
  contract → claim → start → report → verify workflow.

  ## Parameters

  - `tenant_id` -- the tenant UUID
  - `stories` -- list of maps with `"story_id"`, `"summary"`, `"review_type"`
  - `orchestrator_agent_id` -- the orchestrator's agent UUID (used for audit)
  - `opts` -- keyword list with `:actor_id`, `:actor_label`

  ## Returns

  - `{:ok, results}` -- list of per-story results (partial-success semantics)
  - `{:error, :batch_too_large}` -- if batch exceeds max size
  - `{:error, :empty_batch}` -- if stories list is empty
  """
  @spec bulk_mark_complete(Ecto.UUID.t(), [map()], Ecto.UUID.t() | nil, keyword()) ::
          {:ok, [map()]} | {:error, atom()}
  def bulk_mark_complete(tenant_id, stories, orchestrator_agent_id, opts \\ []) do
    story_ids = Enum.map(stories, &(&1["story_id"] || &1[:story_id]))

    with :ok <- validate_batch_size(story_ids) do
      actor_id = Keyword.get(opts, :actor_id)
      actor_label = Keyword.get(opts, :actor_label)

      story_params =
        Map.new(stories, fn s ->
          sid = s["story_id"] || s[:story_id]
          {sid, s}
        end)

      sorted_ids = Enum.sort(story_ids)

      ctx = %{
        tenant_id: tenant_id,
        orch_id: orchestrator_agent_id,
        actor_id: actor_id,
        actor_label: actor_label
      }

      AdminRepo.transaction(fn ->
        locked_stories = lock_stories_by_ids(tenant_id, sorted_ids)
        # ONE audit query for the batch, taken before the per-story loop: the guard
        # used to run it per story while holding FOR UPDATE locks on all of them.
        lifecycle_ids = Progress.stories_with_lifecycle_history(tenant_id, sorted_ids)
        ctx = Map.put(ctx, :lifecycle_ids, lifecycle_ids)
        process_mark_completes(sorted_ids, locked_stories, story_params, ctx)
      end)
    end
  end

  # ===================================================================
  # Private: Batch Processors (reduce nesting by extracting from transaction body)
  # ===================================================================

  defp process_mark_completes(sorted_ids, locked_stories, story_params, ctx) do
    Enum.map(sorted_ids, fn story_id ->
      params = Map.get(story_params, story_id, %{})

      case Map.get(locked_stories, story_id) do
        nil ->
          %{story_id: story_id, status: "error", reason: "Story not found"}

        story ->
          process_mark_complete(story, params, ctx)
      end
    end)
  end

  defp process_mark_complete(story, params, ctx) do
    %{
      tenant_id: tenant_id,
      orch_id: orchestrator_agent_id,
      actor_id: actor_id,
      actor_label: actor_label
    } = ctx

    with :ok <- Progress.ensure_mark_complete_allowed(story, ctx.lifecycle_ids),
         {:ok, updated} <- apply_mark_complete(story) do
      create_mark_complete_result(tenant_id, story, orchestrator_agent_id, params)

      audit_mark_complete(
        tenant_id,
        story,
        updated,
        actor_id,
        actor_label,
        orchestrator_agent_id
      )

      emit_mark_complete_event(tenant_id, updated, orchestrator_agent_id, params)
      %{story_id: story.id, status: "success"}
    else
      {:error, reason} ->
        %{story_id: story.id, status: "error", reason: format_reason(reason)}
    end
  end

  defp process_claims(sorted_ids, locked_stories, agent_id, tenant_id, actor_id, actor_label) do
    Enum.map(sorted_ids, fn story_id ->
      case Map.get(locked_stories, story_id) do
        nil -> %{story_id: story_id, status: "error", reason: "Story not found"}
        story -> process_claim(story, agent_id, tenant_id, actor_id, actor_label)
      end
    end)
  end

  defp process_verifications(sorted_ids, locked_stories, story_params, ctx) do
    Enum.map(sorted_ids, fn story_id ->
      params = Map.get(story_params, story_id, %{})

      case Map.get(locked_stories, story_id) do
        nil ->
          %{story_id: story_id, status: "error", reason: "Story not found"}

        story ->
          process_verify(story, params, ctx)
      end
    end)
  end

  defp process_rejections(sorted_ids, locked_stories, story_params, ctx) do
    Enum.map(sorted_ids, fn story_id ->
      params = Map.get(story_params, story_id, %{})

      case Map.get(locked_stories, story_id) do
        nil ->
          %{story_id: story_id, status: "error", reason: "Story not found"}

        story ->
          process_reject(story, params, ctx)
      end
    end)
  end

  # The CALLER's dispatch lineage, resolved SERVER-SIDE from the authenticating key —
  # never client-supplied. Without it `ensure_verify_allowed/4` saw an empty lineage,
  # `lineage_status/2` read that as "no conflict", and bulk verify/reject degraded to
  # agent-id inequality — a condition any orchestrator key satisfies trivially.
  #
  # `LoopctlWeb.BulkOperationsController` passes `:verifier_lineage` explicitly, from
  # `Dispatches.lineage_for_api_key(tenant_id, conn.assigns.current_api_key.id)` — the
  # SAME expression `LoopctlWeb.StoryVerificationController` uses on the single-story
  # path, so the two gates cannot disagree about which principal is calling. The
  # `:actor_id` fallback below serves DIRECT context callers only. It resolves to the
  # same key today (`AuditContext.from_conn/1` carries the authenticating key's id),
  # but `:actor_id` is an audit-ATTRIBUTION field, not a security identity: a future
  # change to what gets attributed would silently move the L4 gate with it. Do not make
  # the HTTP path depend on it again.
  defp caller_lineage(tenant_id, opts) do
    Keyword.get_lazy(opts, :verifier_lineage, fn ->
      Dispatches.lineage_for_api_key(tenant_id, Keyword.get(opts, :actor_id))
    end)
  end

  # ===================================================================
  # Private: Individual Story Processing
  # ===================================================================

  defp process_claim(story, agent_id, tenant_id, actor_id, actor_label) do
    with :ok <- validate_claim_preconditions(story),
         {:ok, updated} <- apply_claim(story, agent_id) do
      audit_claim(tenant_id, story, updated, actor_id, actor_label)
      emit_claim_event(tenant_id, story, updated, agent_id)
      %{story_id: story.id, status: "success"}
    else
      {:error, reason} ->
        %{story_id: story.id, status: "error", reason: format_reason(reason)}
    end
  end

  defp process_verify(story, params, ctx) do
    %{
      tenant_id: tenant_id,
      orch_id: orchestrator_agent_id,
      actor_id: actor_id,
      actor_label: actor_label
    } = ctx

    with :ok <- validate_verify_preconditions(story),
         :ok <- Progress.ensure_verify_allowed(story, orchestrator_agent_id, ctx.caller_lineage),
         :ok <- Progress.ensure_review_conducted(tenant_id, story.id, story),
         {:ok, updated} <- apply_verification(story) do
      create_verification_result(tenant_id, story, orchestrator_agent_id, params)
      audit_verification(tenant_id, story, updated, actor_id, actor_label, orchestrator_agent_id)
      emit_verify_event(tenant_id, updated, orchestrator_agent_id, params)
      %{story_id: story.id, status: "success"}
    else
      {:error, reason} ->
        %{story_id: story.id, status: "error", reason: format_reason(reason)}
    end
  end

  defp process_reject(story, params, ctx) do
    require Logger

    %{
      tenant_id: tenant_id,
      orch_id: orchestrator_agent_id,
      actor_id: actor_id,
      actor_label: actor_label
    } = ctx

    reason = params["reason"] || params[:reason]

    with :ok <- validate_reason(reason),
         :ok <- validate_reject_preconditions(story),
         :ok <-
           Progress.ensure_verify_allowed(
             story,
             orchestrator_agent_id,
             ctx.caller_lineage,
             :reject
           ),
         {:ok, updated} <- apply_rejection(story, reason) do
      create_rejection_result(tenant_id, story, orchestrator_agent_id, params)
      audit_rejection(tenant_id, story, updated, actor_id, actor_label, orchestrator_agent_id)
      emit_reject_event(tenant_id, updated, orchestrator_agent_id, reason)

      case auto_reset_agent_status(updated) do
        {:ok, reset} ->
          audit_auto_reset(tenant_id, updated, reset, actor_id, actor_label)

        {:error, reset_reason} ->
          Logger.warning("Auto-reset failed for story #{story.id}: #{inspect(reset_reason)}")
      end

      %{story_id: story.id, status: "success"}
    else
      {:error, reason} ->
        %{story_id: story.id, status: "error", reason: format_reason(reason)}
    end
  end

  # ===================================================================
  # Private: Validation
  # ===================================================================

  defp validate_batch_size(ids) when is_list(ids) do
    cond do
      Enum.empty?(ids) -> {:error, :empty_batch}
      length(ids) > @max_batch_size -> {:error, :batch_too_large}
      true -> :ok
    end
  end

  defp validate_claim_preconditions(story) do
    if story.agent_status != :contracted do
      {:error, "Story is not in contracted status (current: #{story.agent_status})"}
    else
      check_story_dependencies_satisfied(story)
    end
  end

  defp check_story_dependencies_satisfied(story) do
    unmet_count =
      from(sd in Loopctl.WorkBreakdown.StoryDependency,
        join: dep in Story,
        on: dep.id == sd.depends_on_story_id,
        where: sd.story_id == ^story.id and dep.verified_status != :verified,
        select: count(sd.id)
      )
      |> AdminRepo.one()

    if unmet_count > 0 do
      {:error, "Story has #{unmet_count} unverified dependency(ies)"}
    else
      check_epic_dependencies_satisfied(story)
    end
  end

  defp check_epic_dependencies_satisfied(story) do
    unmet_count =
      from(ed in Loopctl.WorkBreakdown.EpicDependency,
        where: ed.epic_id == ^story.epic_id,
        join: prereq_story in Story,
        on: prereq_story.epic_id == ed.depends_on_epic_id,
        where: prereq_story.verified_status != :verified,
        select: count(prereq_story.id)
      )
      |> AdminRepo.one()

    if unmet_count > 0 do
      {:error, "Parent epic has #{unmet_count} unverified prerequisite story(ies)"}
    else
      :ok
    end
  end

  defp validate_verify_preconditions(story) do
    cond do
      story.verified_status == :verified ->
        {:error, :already_verified}

      story.agent_status == :reported_done ->
        :ok

      true ->
        {:error,
         "Story must be in reported_done status to verify (current: #{story.agent_status})"}
    end
  end

  defp validate_reject_preconditions(story) do
    if story.agent_status == :reported_done do
      :ok
    else
      {:error, "Story must be in reported_done status to reject (current: #{story.agent_status})"}
    end
  end

  defp validate_reason(nil), do: {:error, :reason_required}
  defp validate_reason(""), do: {:error, :reason_required}
  defp validate_reason(reason) when is_binary(reason), do: :ok
  defp validate_reason(_), do: {:error, :reason_required}

  # ===================================================================
  # Private: Locking
  # ===================================================================

  defp lock_stories_by_ids(tenant_id, sorted_ids) do
    Story
    |> where([s], s.id in ^sorted_ids and s.tenant_id == ^tenant_id)
    |> order_by([s], asc: s.id)
    |> lock("FOR UPDATE")
    |> AdminRepo.all()
    |> Map.new(&{&1.id, &1})
  end

  # ===================================================================
  # Private: Apply Operations
  # ===================================================================

  defp apply_claim(story, agent_id) do
    now = DateTime.utc_now()

    story
    |> Ecto.Changeset.change(%{
      agent_status: :assigned,
      assigned_agent_id: agent_id,
      assigned_at: now
    })
    |> AdminRepo.update()
  end

  defp apply_verification(story) do
    now = DateTime.utc_now()

    story
    |> Ecto.Changeset.change(%{
      verified_status: :verified,
      verified_at: now,
      rejected_at: nil,
      rejection_reason: nil
    })
    |> AdminRepo.update()
  end

  defp apply_rejection(story, reason) do
    now = DateTime.utc_now()

    story
    |> Ecto.Changeset.change(%{
      verified_status: :rejected,
      rejected_at: now,
      rejection_reason: reason
    })
    |> AdminRepo.update()
  end

  defp apply_mark_complete(story) do
    now = DateTime.utc_now()

    story
    |> Ecto.Changeset.change(%{
      agent_status: :reported_done,
      # Preserve an existing reported_done_at (e.g. a story imported with
      # initial_agent_status="reported_done" carries pre-loopctl-done provenance);
      # only stamp `now` when there is none. Matches backfill_story's behavior.
      reported_done_at: story.reported_done_at || now,
      verified_status: :verified,
      verified_at: now,
      rejected_at: nil,
      rejection_reason: nil
    })
    |> AdminRepo.update()
  end

  defp auto_reset_agent_status(story) do
    story
    |> Ecto.Changeset.change(%{
      agent_status: :pending,
      assigned_agent_id: nil,
      assigned_at: nil,
      reported_done_at: nil,
      # The FOURTH site that clears assigned_agent_id on a worked story, and the twin
      # of Progress.perform_auto_reset/4. Without the stamp the backfill guard here
      # rests on `verified_status: :rejected` alone — the coincidence the single-story
      # path was stamped to stop depending on. See Progress.guard_no_lifecycle_history/2.
      lifecycle_entered_at: Progress.lifecycle_stamp(story)
    })
    |> AdminRepo.update()
  end

  # ===================================================================
  # Private: Verification/Rejection Result Records
  # ===================================================================

  defp create_verification_result(tenant_id, story, orchestrator_agent_id, params) do
    require Logger
    iteration = count_verifications(tenant_id, story.id) + 1

    case %VerificationResult{
           tenant_id: tenant_id,
           story_id: story.id,
           orchestrator_agent_id: orchestrator_agent_id
         }
         |> VerificationResult.create_changeset(%{
           result: :pass,
           summary: params["summary"] || params[:summary] || "Verified via bulk operation",
           findings: params["findings"] || params[:findings] || %{},
           review_type: params["review_type"] || "bulk_verify",
           iteration: iteration
         })
         |> AdminRepo.insert() do
      {:ok, result} ->
        result

      {:error, reason} ->
        Logger.warning(
          "Failed to create verification result for story #{story.id}: #{inspect(reason)}"
        )

        nil
    end
  end

  defp create_rejection_result(tenant_id, story, orchestrator_agent_id, params) do
    require Logger
    reason = params["reason"] || params[:reason]
    iteration = count_verifications(tenant_id, story.id) + 1

    case %VerificationResult{
           tenant_id: tenant_id,
           story_id: story.id,
           orchestrator_agent_id: orchestrator_agent_id
         }
         |> VerificationResult.create_changeset(%{
           result: :fail,
           summary: reason,
           findings: params["findings"] || params[:findings] || %{},
           review_type: params["review_type"] || "bulk_reject",
           iteration: iteration
         })
         |> AdminRepo.insert() do
      {:ok, result} ->
        result

      {:error, reason} ->
        Logger.warning(
          "Failed to create rejection result for story #{story.id}: #{inspect(reason)}"
        )

        nil
    end
  end

  defp create_mark_complete_result(tenant_id, story, orchestrator_agent_id, params) do
    require Logger
    iteration = count_verifications(tenant_id, story.id) + 1
    summary = params["summary"] || params[:summary] || "Marked complete (pre-existing work)"
    review_type = params["review_type"] || "pre_existing"

    case %VerificationResult{
           tenant_id: tenant_id,
           story_id: story.id,
           orchestrator_agent_id: orchestrator_agent_id
         }
         |> VerificationResult.create_changeset(%{
           result: :pass,
           summary: summary,
           findings: %{},
           review_type: review_type,
           iteration: iteration
         })
         |> AdminRepo.insert() do
      {:ok, result} ->
        result

      {:error, reason} ->
        Logger.warning(
          "Failed to create mark_complete result for story #{story.id}: #{inspect(reason)}"
        )

        nil
    end
  end

  defp count_verifications(tenant_id, story_id) do
    VerificationResult
    |> where([v], v.tenant_id == ^tenant_id and v.story_id == ^story_id)
    |> AdminRepo.aggregate(:count, :id)
  end

  # ===================================================================
  # Private: Audit Logging
  # ===================================================================

  defp audit_claim(tenant_id, old_story, updated, actor_id, actor_label) do
    Audit.create_log_entry(tenant_id, %{
      entity_type: "story",
      entity_id: updated.id,
      action: "status_changed",
      actor_type: "api_key",
      actor_id: actor_id,
      actor_label: actor_label,
      old_state: %{"agent_status" => to_string(old_story.agent_status)},
      new_state: %{
        "agent_status" => to_string(updated.agent_status),
        "assigned_agent_id" => updated.assigned_agent_id
      }
    })
  end

  defp audit_verification(tenant_id, old_story, updated, actor_id, actor_label, orch_id) do
    Audit.create_log_entry(tenant_id, %{
      entity_type: "story",
      entity_id: updated.id,
      action: "verified",
      actor_type: "api_key",
      actor_id: actor_id,
      actor_label: actor_label,
      old_state: %{"verified_status" => to_string(old_story.verified_status)},
      new_state: %{
        "verified_status" => to_string(updated.verified_status),
        "orchestrator_agent_id" => orch_id
      }
    })
  end

  defp audit_rejection(tenant_id, old_story, updated, actor_id, actor_label, orch_id) do
    Audit.create_log_entry(tenant_id, %{
      entity_type: "story",
      entity_id: updated.id,
      action: "rejected",
      actor_type: "api_key",
      actor_id: actor_id,
      actor_label: actor_label,
      old_state: %{"verified_status" => to_string(old_story.verified_status)},
      new_state: %{
        "verified_status" => to_string(updated.verified_status),
        "orchestrator_agent_id" => orch_id,
        "rejection_reason" => updated.rejection_reason
      }
    })
  end

  defp audit_mark_complete(tenant_id, old_story, updated, actor_id, actor_label, orch_id) do
    Audit.create_log_entry(tenant_id, %{
      entity_type: "story",
      entity_id: updated.id,
      action: "mark_complete",
      actor_type: "api_key",
      actor_id: actor_id,
      actor_label: actor_label,
      old_state: %{
        "agent_status" => to_string(old_story.agent_status),
        "verified_status" => to_string(old_story.verified_status)
      },
      new_state: %{
        "agent_status" => to_string(updated.agent_status),
        "verified_status" => to_string(updated.verified_status),
        "orchestrator_agent_id" => orch_id
      }
    })
  end

  defp audit_auto_reset(tenant_id, old_story, reset_story, actor_id, actor_label) do
    Audit.create_log_entry(tenant_id, %{
      entity_type: "story",
      entity_id: reset_story.id,
      action: "auto_reset",
      actor_type: "api_key",
      actor_id: actor_id,
      actor_label: actor_label,
      old_state: %{"agent_status" => to_string(old_story.agent_status)},
      new_state: %{"agent_status" => to_string(reset_story.agent_status)}
    })
  end

  # ===================================================================
  # Private: Webhook Events
  # ===================================================================

  defp emit_claim_event(tenant_id, _old_story, updated, agent_id) do
    emit_story_event(tenant_id, "story.status_changed", updated, %{
      "event" => "story.status_changed",
      "story_id" => updated.id,
      "project_id" => updated.project_id,
      "epic_id" => updated.epic_id,
      "new_status" => to_string(updated.agent_status),
      "agent_id" => agent_id,
      "timestamp" => DateTime.to_iso8601(DateTime.utc_now())
    })
  end

  defp emit_verify_event(tenant_id, updated, orchestrator_agent_id, params) do
    emit_story_event(tenant_id, "story.verified", updated, %{
      "event" => "story.verified",
      "story_id" => updated.id,
      "project_id" => updated.project_id,
      "epic_id" => updated.epic_id,
      "orchestrator_agent_id" => orchestrator_agent_id,
      "summary" => params["summary"] || params[:summary],
      "timestamp" => DateTime.to_iso8601(DateTime.utc_now())
    })
  end

  defp emit_reject_event(tenant_id, updated, orchestrator_agent_id, reason) do
    emit_story_event(tenant_id, "story.rejected", updated, %{
      "event" => "story.rejected",
      "story_id" => updated.id,
      "project_id" => updated.project_id,
      "epic_id" => updated.epic_id,
      "orchestrator_agent_id" => orchestrator_agent_id,
      "reason" => reason,
      "timestamp" => DateTime.to_iso8601(DateTime.utc_now())
    })
  end

  defp emit_mark_complete_event(tenant_id, updated, orchestrator_agent_id, params) do
    emit_story_event(tenant_id, "story.verified", updated, %{
      "event" => "story.verified",
      "story_id" => updated.id,
      "project_id" => updated.project_id,
      "epic_id" => updated.epic_id,
      "orchestrator_agent_id" => orchestrator_agent_id,
      "summary" => params["summary"] || params[:summary] || "Marked complete (pre-existing work)",
      "review_type" => params["review_type"] || "pre_existing",
      "timestamp" => DateTime.to_iso8601(DateTime.utc_now())
    })
  end

  defp emit_story_event(tenant_id, event_type, story, payload) do
    require Logger
    webhooks = EventGenerator.matching_webhooks(tenant_id, event_type, story.project_id)

    Enum.each(webhooks, fn webhook ->
      emit_single_webhook_event(tenant_id, webhook, event_type, payload)
    end)
  end

  defp emit_single_webhook_event(tenant_id, webhook, event_type, payload) do
    require Logger

    with {:ok, event} <-
           %WebhookEvent{tenant_id: tenant_id, webhook_id: webhook.id}
           |> WebhookEvent.create_changeset(%{event_type: event_type, payload: payload})
           |> AdminRepo.insert(),
         {:ok, _job} <-
           WebhookDeliveryWorker.new(%{webhook_event_id: event.id, tenant_id: tenant_id})
           |> Oban.insert() do
      :ok
    else
      {:error, reason} ->
        Logger.warning(
          "Failed webhook event/delivery for webhook #{webhook.id}: #{inspect(reason)}"
        )
    end
  end

  # ===================================================================
  # Private: Helpers
  # ===================================================================

  defp format_reason(:reason_required), do: "reason is required and cannot be blank"

  defp format_reason(:self_verify_blocked),
    do: "cannot verify your own implemented work (chain-of-custody)"

  defp format_reason(:unresolvable_dispatch_lineage),
    do:
      "a dispatch referenced by this story (the implementer's, or the verifier's) could not " <>
        "be resolved, so the custody gate cannot prove the verifier's lineage is separated " <>
        "from the implementer's and failed closed. This is a lineage-integrity failure; " <>
        "re-establish the dispatch provenance before verifying"

  defp format_reason(:missing_assigned_agent),
    do:
      "story is reported_done with no assigned agent or dispatch lineage; its " <>
        "custody chain is broken, so it cannot be verified. If this is " <>
        "never-dispatched / pre-existing work, use mark-complete (bulk) or backfill " <>
        "instead, which record it as done without an agent"

  defp format_reason(:review_not_conducted),
    do: "no independent review record exists for this story since it was reported done"

  defp format_reason(:story_has_dispatch_lineage),
    do:
      "story has dispatch lineage (an assigned agent or dispatch id); use the normal " <>
        "report → review → verify flow, not mark-complete"

  defp format_reason(:story_entered_lifecycle),
    do:
      "story is recorded as having entered the dispatch lifecycle (a status change, a " <>
        "force-unclaim or an auto-reset), even though its dispatch markers are now clear; " <>
        "use the normal report → review → verify flow, not mark-complete. The record is " <>
        "the story's own lifecycle stamp, the audit log, or both — the audit log is pruned " <>
        "at AUDIT_RETENTION_DAYS, so an empty story history does not contradict this"

  defp format_reason(:story_in_progress),
    do:
      "story is mid-lifecycle (being worked) with no dispatch lineage yet; it is not " <>
        "pre-existing done work, so mark-complete does not apply"

  defp format_reason(:already_verified), do: "story is already verified"

  defp format_reason(:story_rejected),
    do: "story is rejected; investigate instead of marking it complete"

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)
end
