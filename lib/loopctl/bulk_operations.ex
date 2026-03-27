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
        actor_label: actor_label
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
        actor_label: actor_label
      }

      AdminRepo.transaction(fn ->
        locked_stories = lock_stories_by_ids(tenant_id, sorted_ids)
        process_rejections(sorted_ids, locked_stories, story_params, ctx)
      end)
    end
  end

  # ===================================================================
  # Private: Batch Processors (reduce nesting by extracting from transaction body)
  # ===================================================================

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
          process_verify(story, params, ctx.tenant_id, ctx.orch_id, ctx.actor_id, ctx.actor_label)
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
          process_reject(story, params, ctx.tenant_id, ctx.orch_id, ctx.actor_id, ctx.actor_label)
      end
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

  defp process_verify(story, params, tenant_id, orchestrator_agent_id, actor_id, actor_label) do
    with :ok <- validate_verify_preconditions(story),
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

  defp process_reject(story, params, tenant_id, orchestrator_agent_id, actor_id, actor_label) do
    require Logger
    reason = params["reason"] || params[:reason]

    with :ok <- validate_reason(reason),
         :ok <- validate_reject_preconditions(story),
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
    if story.agent_status == :reported_done do
      :ok
    else
      {:error, "Story must be in reported_done status to verify (current: #{story.agent_status})"}
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

  defp auto_reset_agent_status(story) do
    story
    |> Ecto.Changeset.change(%{
      agent_status: :pending,
      assigned_agent_id: nil,
      assigned_at: nil,
      reported_done_at: nil
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
  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)
end
