defmodule Loopctl.Progress do
  @moduledoc """
  Context module for two-tier progress tracking.

  Implements the core trust model where:
  - **Only agents** can write `agent_status` (contract, claim, start, report, unclaim)
  - **Only orchestrators** can write `verified_status` (verify, reject)

  All state transitions are atomic (Ecto.Multi) with audit logging and
  pessimistic locking where needed for concurrency safety.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias Loopctl.AdminRepo
  alias Loopctl.Artifacts.ArtifactReport
  alias Loopctl.Artifacts.ReviewRecord
  alias Loopctl.Artifacts.VerificationResult
  alias Loopctl.Audit
  alias Loopctl.Audit.AuditLog
  alias Loopctl.Tenants
  alias Loopctl.Webhooks.EventGenerator
  alias Loopctl.Webhooks.WebhookEvent
  alias Loopctl.WorkBreakdown.Epic
  alias Loopctl.WorkBreakdown.EpicDependency
  alias Loopctl.WorkBreakdown.Story
  alias Loopctl.WorkBreakdown.StoryDependency
  alias Loopctl.Workers.ReviewKnowledgeWorker
  alias Loopctl.Workers.WebhookDeliveryWorker

  # --- Agent Status Transitions (US-7.1) ---

  @doc """
  Contracts a story: agent acknowledges the story's ACs.

  Transitions agent_status from `pending` to `contracted`.
  The agent must echo the story_title and ac_count to prove they read the story.

  ## Parameters

  - `tenant_id` -- the tenant UUID
  - `story_id` -- the story UUID
  - `params` -- map with `story_title` (string) and `ac_count` (integer)
  - `opts` -- keyword list with `:agent_id`, `:actor_id`, `:actor_label`

  ## Returns

  - `{:ok, %Story{}}` on success
  - `{:error, :not_found}` if story not found in tenant
  - `{:error, :invalid_transition}` if not in pending state
  - `{:error, :title_mismatch}` if echoed title doesn't match
  - `{:error, :ac_count_mismatch}` if echoed AC count doesn't match
  """
  @spec contract_story(Ecto.UUID.t(), Ecto.UUID.t(), map(), keyword()) ::
          {:ok, Story.t()}
          | {:error, atom() | {:contract_mismatch, map()} | {:invalid_transition, map()}}
  def contract_story(tenant_id, story_id, params, opts \\ []) do
    agent_id = Keyword.get(opts, :agent_id)
    actor_id = Keyword.get(opts, :actor_id)
    actor_label = Keyword.get(opts, :actor_label)
    skip_contract_check = Keyword.get(opts, :skip_contract_check, false)

    story_title = Map.get(params, "story_title") || Map.get(params, :story_title)
    ac_count = Map.get(params, "ac_count") || Map.get(params, :ac_count)

    multi =
      Multi.new()
      |> Multi.run(:lock, fn _repo, _changes ->
        lock_story(tenant_id, story_id)
      end)
      |> Multi.run(:validate, fn _repo, %{lock: story} ->
        with :ok <- validate_transition_ctx(story, :contracted, "contract"),
             :ok <- maybe_validate_contract(story, story_title, ac_count, skip_contract_check) do
          {:ok, story}
        end
      end)
      |> Multi.run(:story, fn _repo, %{lock: story} ->
        now = DateTime.utc_now()

        story
        |> Ecto.Changeset.change(%{
          agent_status: :contracted,
          updated_at: now
        })
        |> AdminRepo.update()
      end)
      |> Audit.log_in_multi(:audit, fn %{story: updated, lock: old} ->
        %{
          tenant_id: tenant_id,
          entity_type: "story",
          entity_id: updated.id,
          action: "status_changed",
          actor_type: "api_key",
          actor_id: actor_id,
          actor_label: actor_label,
          old_state: %{"agent_status" => to_string(old.agent_status)},
          new_state: %{
            "agent_status" => to_string(updated.agent_status),
            "agent_id" => agent_id
          }
        }
      end)
      |> EventGenerator.generate_events(:webhook_events, fn %{story: updated, lock: old} ->
        %{
          tenant_id: tenant_id,
          event_type: "story.status_changed",
          project_id: updated.project_id,
          payload: %{
            "event" => "story.status_changed",
            "story_id" => updated.id,
            "project_id" => updated.project_id,
            "epic_id" => updated.epic_id,
            "old_status" => to_string(old.agent_status),
            "new_status" => to_string(updated.agent_status),
            "agent_id" => agent_id,
            "timestamp" => DateTime.to_iso8601(DateTime.utc_now())
          }
        }
      end)

    case AdminRepo.transaction(multi) do
      {:ok, %{story: updated}} -> {:ok, updated}
      {:error, :lock, reason, _} -> {:error, reason}
      {:error, :validate, reason, _} -> {:error, reason}
      {:error, :story, changeset, _} -> {:error, changeset}
    end
  end

  @doc """
  Claims a story: assigns the agent to a contracted story.

  Transitions agent_status from `contracted` to `assigned`.
  Uses pessimistic locking (SELECT FOR UPDATE) to prevent race conditions.

  ## Parameters

  - `tenant_id` -- the tenant UUID
  - `story_id` -- the story UUID
  - `opts` -- keyword list with `:agent_id`, `:actor_id`, `:actor_label`

  ## Returns

  - `{:ok, %Story{}}` on success
  - `{:error, :not_found}` if story not found in tenant
  - `{:error, :invalid_transition}` if not in contracted state
  """
  @spec claim_story(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, Story.t()} | {:error, atom() | {:invalid_transition, map()}}
  def claim_story(tenant_id, story_id, opts \\ []) do
    agent_id = Keyword.get(opts, :agent_id)
    actor_id = Keyword.get(opts, :actor_id)
    actor_label = Keyword.get(opts, :actor_label)

    multi =
      Multi.new()
      |> Multi.run(:lock, fn _repo, _changes ->
        lock_story(tenant_id, story_id)
      end)
      |> Multi.run(:validate, fn _repo, %{lock: story} ->
        case validate_transition_ctx(story, :assigned, "claim") do
          :ok -> {:ok, story}
          error -> error
        end
      end)
      |> Multi.run(:check_deps, fn _repo, %{lock: story} ->
        check_claim_dependencies(story)
      end)
      |> Multi.run(:story, fn _repo, %{lock: story} ->
        now = DateTime.utc_now()

        story
        |> Ecto.Changeset.change(%{
          agent_status: :assigned,
          assigned_agent_id: agent_id,
          assigned_at: now
        })
        |> AdminRepo.update()
      end)
      |> Audit.log_in_multi(:audit, fn %{story: updated, lock: old} ->
        %{
          tenant_id: tenant_id,
          entity_type: "story",
          entity_id: updated.id,
          action: "status_changed",
          actor_type: "api_key",
          actor_id: actor_id,
          actor_label: actor_label,
          old_state: %{"agent_status" => to_string(old.agent_status)},
          new_state: %{
            "agent_status" => to_string(updated.agent_status),
            "assigned_agent_id" => agent_id,
            "agent_id" => agent_id
          }
        }
      end)
      |> EventGenerator.generate_events(:webhook_events, fn %{story: updated, lock: old} ->
        %{
          tenant_id: tenant_id,
          event_type: "story.status_changed",
          project_id: updated.project_id,
          payload: %{
            "event" => "story.status_changed",
            "story_id" => updated.id,
            "project_id" => updated.project_id,
            "epic_id" => updated.epic_id,
            "old_status" => to_string(old.agent_status),
            "new_status" => to_string(updated.agent_status),
            "agent_id" => agent_id,
            "timestamp" => DateTime.to_iso8601(DateTime.utc_now())
          }
        }
      end)

    case AdminRepo.transaction(multi) do
      {:ok, %{story: updated}} -> {:ok, updated}
      {:error, :lock, reason, _} -> {:error, reason}
      {:error, :validate, reason, _} -> {:error, reason}
      {:error, :check_deps, reason, _} -> {:error, reason}
      {:error, :story, changeset, _} -> {:error, changeset}
    end
  end

  @doc """
  Starts work on a story.

  Transitions agent_status from `assigned` to `implementing`.
  Only the assigned agent can start work.

  ## Parameters

  - `tenant_id` -- the tenant UUID
  - `story_id` -- the story UUID
  - `opts` -- keyword list with `:agent_id`, `:actor_id`, `:actor_label`

  ## Returns

  - `{:ok, %Story{}}` on success
  - `{:error, :not_found}` if story not found in tenant
  - `{:error, :invalid_transition}` if not in assigned state
  - `{:error, :not_assigned_agent}` if calling agent is not the assigned agent
  """
  @spec start_story(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, Story.t()} | {:error, atom() | {:invalid_transition, map()}}
  def start_story(tenant_id, story_id, opts \\ []) do
    agent_id = Keyword.get(opts, :agent_id)
    actor_id = Keyword.get(opts, :actor_id)
    actor_label = Keyword.get(opts, :actor_label)

    multi =
      Multi.new()
      |> Multi.run(:lock, fn _repo, _changes ->
        lock_story(tenant_id, story_id)
      end)
      |> Multi.run(:validate, fn _repo, %{lock: story} ->
        with :ok <- validate_transition_ctx(story, :implementing, "start"),
             :ok <- validate_assigned_agent(story, agent_id) do
          {:ok, story}
        end
      end)
      |> Multi.run(:story, fn _repo, %{lock: story} ->
        story
        |> Ecto.Changeset.change(%{
          agent_status: :implementing
        })
        |> AdminRepo.update()
      end)
      |> Audit.log_in_multi(:audit, fn %{story: updated, lock: old} ->
        %{
          tenant_id: tenant_id,
          entity_type: "story",
          entity_id: updated.id,
          action: "status_changed",
          actor_type: "api_key",
          actor_id: actor_id,
          actor_label: actor_label,
          old_state: %{"agent_status" => to_string(old.agent_status)},
          new_state: %{
            "agent_status" => to_string(updated.agent_status),
            "agent_id" => agent_id
          }
        }
      end)
      |> EventGenerator.generate_events(:webhook_events, fn %{story: updated, lock: old} ->
        %{
          tenant_id: tenant_id,
          event_type: "story.status_changed",
          project_id: updated.project_id,
          payload: %{
            "event" => "story.status_changed",
            "story_id" => updated.id,
            "project_id" => updated.project_id,
            "epic_id" => updated.epic_id,
            "old_status" => to_string(old.agent_status),
            "new_status" => to_string(updated.agent_status),
            "agent_id" => agent_id,
            "timestamp" => DateTime.to_iso8601(DateTime.utc_now())
          }
        }
      end)

    case AdminRepo.transaction(multi) do
      {:ok, %{story: updated}} -> {:ok, updated}
      {:error, :lock, reason, _} -> {:error, reason}
      {:error, :validate, reason, _} -> {:error, reason}
      {:error, :story, changeset, _} -> {:error, changeset}
    end
  end

  @doc """
  Reports a story as done.

  Transitions agent_status from `implementing` to `reported_done`.
  Optionally accepts an artifact report that is created atomically.
  A DIFFERENT agent from the implementer must call this (chain-of-custody enforcement).
  The calling agent is recorded as `reported_by_agent_id`.

  ## Parameters

  - `tenant_id` -- the tenant UUID
  - `story_id` -- the story UUID
  - `opts` -- keyword list with `:agent_id`, `:actor_id`, `:actor_label`
  - `artifact_params` -- optional map with artifact report data

  ## Returns

  - `{:ok, %Story{}}` on success
  - `{:error, :not_found}` if story not found in tenant
  - `{:error, :invalid_transition}` if not in implementing state
  - `{:error, :self_report_blocked}` if calling agent is the same as the assigned agent
  - `{:error, %Ecto.Changeset{}}` if artifact validation fails
  """
  @spec report_story(Ecto.UUID.t(), Ecto.UUID.t(), keyword(), map() | nil) ::
          {:ok, Story.t()} | {:error, atom() | {:invalid_transition, map()} | Ecto.Changeset.t()}
  def report_story(tenant_id, story_id, opts \\ [], artifact_params \\ nil) do
    agent_id = Keyword.get(opts, :agent_id)
    actor_id = Keyword.get(opts, :actor_id)
    actor_label = Keyword.get(opts, :actor_label)
    token_usage_params = Keyword.get(opts, :token_usage)

    multi =
      Multi.new()
      |> Multi.run(:lock, fn _repo, _changes ->
        lock_story(tenant_id, story_id)
      end)
      |> Multi.run(:validate, fn _repo, %{lock: story} ->
        with :ok <- validate_transition_ctx(story, :reported_done, "report"),
             :ok <- validate_not_self_report(story, agent_id) do
          {:ok, story}
        end
      end)
      |> Multi.run(:story, fn _repo, %{lock: story} ->
        now = DateTime.utc_now()

        story
        |> Ecto.Changeset.change(%{
          agent_status: :reported_done,
          reported_done_at: now,
          reported_by_agent_id: agent_id
        })
        |> AdminRepo.update()
      end)
      |> maybe_create_artifact(tenant_id, story_id, agent_id, artifact_params)
      |> maybe_create_token_usage_report(tenant_id, story_id, agent_id, token_usage_params)
      |> Audit.log_in_multi(:audit, fn %{story: updated, lock: old} ->
        %{
          tenant_id: tenant_id,
          entity_type: "story",
          entity_id: updated.id,
          action: "status_changed",
          actor_type: "api_key",
          actor_id: actor_id,
          actor_label: actor_label,
          old_state: %{"agent_status" => to_string(old.agent_status)},
          new_state: %{
            "agent_status" => to_string(updated.agent_status),
            "reported_done_at" => to_string(updated.reported_done_at),
            "agent_id" => agent_id
          }
        }
      end)
      |> maybe_audit_token_usage(tenant_id, actor_id, actor_label, token_usage_params)
      |> EventGenerator.generate_events(:webhook_events, fn %{story: updated, lock: old} ->
        %{
          tenant_id: tenant_id,
          event_type: "story.status_changed",
          project_id: updated.project_id,
          payload: %{
            "event" => "story.status_changed",
            "story_id" => updated.id,
            "project_id" => updated.project_id,
            "epic_id" => updated.epic_id,
            "old_status" => to_string(old.agent_status),
            "new_status" => to_string(updated.agent_status),
            "agent_id" => agent_id,
            "timestamp" => DateTime.to_iso8601(DateTime.utc_now())
          }
        }
      end)

    case AdminRepo.transaction(multi) do
      {:ok, %{story: updated}} -> {:ok, updated}
      {:error, :lock, reason, _} -> {:error, reason}
      {:error, :validate, reason, _} -> {:error, reason}
      {:error, :story, changeset, _} -> {:error, changeset}
      {:error, :artifact, changeset, _} -> {:error, changeset}
      {:error, :token_usage_report, changeset, _} -> {:error, changeset}
    end
  end

  @doc """
  Signals that the assigned agent has finished implementation and requests review.

  Does NOT change agent_status. Fires a `story.review_requested` webhook event.
  Only the assigned agent can call this. Story must be in `implementing` status.

  ## Parameters

  - `tenant_id` -- the tenant UUID
  - `story_id` -- the story UUID
  - `opts` -- keyword list with `:agent_id`, `:actor_id`, `:actor_label`

  ## Returns

  - `{:ok, %Story{}}` on success
  - `{:error, :not_found}` if story not found in tenant
  - `{:error, :not_assigned_agent}` if caller is not the assigned agent
  - `{:error, {:invalid_transition, map()}}` if story is not in implementing status
  """
  @spec request_review(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, Story.t()} | {:error, atom() | {:invalid_transition, map()}}
  def request_review(tenant_id, story_id, opts \\ []) do
    agent_id = Keyword.get(opts, :agent_id)

    query =
      Story
      |> where([s], s.id == ^story_id and s.tenant_id == ^tenant_id)

    case AdminRepo.one(query) do
      nil ->
        {:error, :not_found}

      story ->
        with :ok <- validate_story_implementing(story),
             :ok <- validate_assigned_agent(story, agent_id) do
          insert_events_with_delivery(tenant_id, "story.review_requested", story.project_id, %{
            "event" => "story.review_requested",
            "story_id" => story_id,
            "project_id" => story.project_id,
            "epic_id" => story.epic_id,
            "agent_id" => agent_id,
            "timestamp" => DateTime.to_iso8601(DateTime.utc_now())
          })

          {:ok, story}
        end
    end
  end

  @doc """
  Unclaims a story: resets it to pending.

  Only the assigned agent can unclaim (unless already pending).
  Works from any agent_status except pending.

  ## Parameters

  - `tenant_id` -- the tenant UUID
  - `story_id` -- the story UUID
  - `opts` -- keyword list with `:agent_id`, `:actor_id`, `:actor_label`

  ## Returns

  - `{:ok, %Story{}}` on success
  - `{:error, :not_found}` if story not found in tenant
  - `{:error, :invalid_transition}` if already pending
  - `{:error, :not_assigned_agent}` if calling agent is not the assigned agent
  """
  @spec unclaim_story(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, Story.t()} | {:error, atom()}
  def unclaim_story(tenant_id, story_id, opts \\ []) do
    agent_id = Keyword.get(opts, :agent_id)
    actor_id = Keyword.get(opts, :actor_id)
    actor_label = Keyword.get(opts, :actor_label)

    multi =
      Multi.new()
      |> Multi.run(:lock, fn _repo, _changes ->
        lock_story(tenant_id, story_id)
      end)
      |> Multi.run(:validate, fn _repo, %{lock: story} ->
        case validate_unclaim(story, agent_id) do
          :ok -> {:ok, story}
          error -> error
        end
      end)
      |> Multi.run(:story, fn _repo, %{lock: story} ->
        story
        |> Ecto.Changeset.change(%{
          agent_status: :pending,
          assigned_agent_id: nil,
          assigned_at: nil,
          reported_done_at: nil,
          reported_by_agent_id: nil
        })
        |> AdminRepo.update()
      end)
      |> Audit.log_in_multi(:audit, fn %{story: updated, lock: old} ->
        %{
          tenant_id: tenant_id,
          entity_type: "story",
          entity_id: updated.id,
          action: "status_changed",
          actor_type: "api_key",
          actor_id: actor_id,
          actor_label: actor_label,
          old_state: %{
            "agent_status" => to_string(old.agent_status),
            "assigned_agent_id" => old.assigned_agent_id
          },
          new_state: %{"agent_status" => "pending", "agent_id" => agent_id}
        }
      end)
      |> EventGenerator.generate_events(:webhook_events, fn %{story: updated, lock: old} ->
        %{
          tenant_id: tenant_id,
          event_type: "story.status_changed",
          project_id: updated.project_id,
          payload: %{
            "event" => "story.status_changed",
            "story_id" => updated.id,
            "project_id" => updated.project_id,
            "epic_id" => updated.epic_id,
            "old_status" => to_string(old.agent_status),
            "new_status" => "pending",
            "agent_id" => agent_id,
            "timestamp" => DateTime.to_iso8601(DateTime.utc_now())
          }
        }
      end)

    case AdminRepo.transaction(multi) do
      {:ok, %{story: updated}} -> {:ok, updated}
      {:error, :lock, reason, _} -> {:error, reason}
      {:error, :validate, reason, _} -> {:error, reason}
      {:error, :story, changeset, _} -> {:error, changeset}
    end
  end

  # --- Review Records ---

  @doc """
  Records that an independent review was completed for a story.

  Creates a `review_record` proving the review pipeline ran. The `verify_story/4`
  function checks for the existence of a valid review record (completed AFTER
  `reported_done_at`) before allowing verification to proceed.

  ## Parameters

  - `tenant_id` -- the tenant UUID
  - `story_id` -- the story UUID
  - `params` -- map with `review_type` (required), optional `findings_count`,
    `fixes_count`, `summary`, `completed_at`
  - `opts` -- keyword list with `:reviewer_agent_id`, `:actor_id`, `:actor_label`

  ## Returns

  - `{:ok, %ReviewRecord{}}` on success
  - `{:error, :not_found}` if story not found in tenant
  - `{:error, :story_not_reported_done}` if story is not in reported_done status
  - `{:error, %Ecto.Changeset{}}` on validation failure
  """
  @spec record_review(Ecto.UUID.t(), Ecto.UUID.t(), map(), keyword()) ::
          {:ok, ReviewRecord.t()} | {:error, atom() | Ecto.Changeset.t()}
  def record_review(tenant_id, story_id, params, opts \\ []) do
    reviewer_agent_id = Keyword.get(opts, :reviewer_agent_id)

    with {:ok, story} <- fetch_story_for_review(tenant_id, story_id),
         :ok <- validate_story_reported_done(story),
         :ok <- validate_not_self_review(story, reviewer_agent_id) do
      attrs = build_review_attrs(params)

      changeset =
        %ReviewRecord{
          tenant_id: tenant_id,
          story_id: story_id,
          reviewer_agent_id: reviewer_agent_id
        }
        |> ReviewRecord.create_changeset(attrs)

      multi =
        Multi.new()
        |> Multi.insert(:review_record, changeset)
        |> enqueue_knowledge_extraction(tenant_id)

      handle_review_transaction(
        AdminRepo.transaction(multi),
        tenant_id,
        story,
        attrs,
        reviewer_agent_id
      )
    end
  end

  defp build_review_attrs(params) do
    %{
      review_type: Map.get(params, "review_type") || Map.get(params, :review_type),
      findings_count: Map.get(params, "findings_count") || Map.get(params, :findings_count, 0),
      fixes_count: Map.get(params, "fixes_count") || Map.get(params, :fixes_count, 0),
      disproved_count: Map.get(params, "disproved_count") || Map.get(params, :disproved_count, 0),
      summary: Map.get(params, "summary") || Map.get(params, :summary),
      completed_at:
        Map.get(params, "completed_at") || Map.get(params, :completed_at) || DateTime.utc_now()
    }
  end

  defp enqueue_knowledge_extraction(multi, tenant_id) do
    Multi.run(multi, :enqueue_knowledge_worker, fn _repo, %{review_record: rr} ->
      tenant = AdminRepo.get(Tenants.Tenant, tenant_id)

      if knowledge_auto_extract_enabled?(tenant) do
        ReviewKnowledgeWorker.new(%{review_record_id: rr.id, tenant_id: tenant_id})
        |> Oban.insert()
      else
        {:ok, :skipped}
      end
    end)
  end

  defp knowledge_auto_extract_enabled?(nil), do: true

  defp knowledge_auto_extract_enabled?(%Tenants.Tenant{} = tenant) do
    Tenants.get_tenant_settings(tenant, "knowledge_auto_extract", true) != false
  end

  defp handle_review_transaction(
         {:ok, %{review_record: review_record}},
         tenant_id,
         story,
         attrs,
         reviewer_agent_id
       ) do
    insert_events_with_delivery(tenant_id, "story.review_completed", story.project_id, %{
      "event" => "story.review_completed",
      "story_id" => story.id,
      "project_id" => story.project_id,
      "epic_id" => story.epic_id,
      "reviewer_agent_id" => reviewer_agent_id,
      "review_type" => attrs.review_type,
      "findings_count" => attrs.findings_count,
      "timestamp" => DateTime.to_iso8601(DateTime.utc_now())
    })

    {:ok, review_record}
  end

  defp handle_review_transaction({:error, :review_record, changeset, _}, _, _, _, _) do
    {:error, changeset}
  end

  defp handle_review_transaction({:error, :enqueue_knowledge_worker, reason, _}, _, _, _, _) do
    {:error, reason}
  end

  defp fetch_story_for_review(tenant_id, story_id) do
    query =
      Story
      |> where([s], s.id == ^story_id and s.tenant_id == ^tenant_id)

    case AdminRepo.one(query) do
      nil -> {:error, :not_found}
      story -> {:ok, story}
    end
  end

  defp validate_story_reported_done(%Story{agent_status: :reported_done}), do: :ok

  defp validate_story_reported_done(_story), do: {:error, :story_not_reported_done}

  # --- Orchestrator Verification (US-7.2) ---

  @doc """
  Verifies a story: orchestrator marks it as passing verification.

  Sets verified_status to `verified` and creates a verification_result
  record with result=pass. Uses pessimistic locking to prevent duplicate
  verifications. Requires agent_status to be `reported_done`.

  ## Parameters

  - `tenant_id` -- the tenant UUID
  - `story_id` -- the story UUID
  - `params` -- map with `summary` (required), optional `findings`, `review_type`
  - `opts` -- keyword list with `:orchestrator_agent_id`, `:actor_id`, `:actor_label`

  ## Returns

  - `{:ok, %Story{}}` on success
  - `{:error, :not_found}` if story not found in tenant
  - `{:error, :invalid_transition}` if story is not reported_done
  """
  @spec verify_story(Ecto.UUID.t(), Ecto.UUID.t(), map(), keyword()) ::
          {:ok, Story.t()} | {:error, atom() | {:invalid_transition, map()}}
  def verify_story(tenant_id, story_id, params, opts \\ []) do
    orchestrator_agent_id = Keyword.get(opts, :orchestrator_agent_id)
    actor_id = Keyword.get(opts, :actor_id)
    actor_label = Keyword.get(opts, :actor_label)

    verification_params = extract_verification_params(params)

    multi =
      Multi.new()
      |> Multi.run(:lock, fn _repo, _changes -> lock_story(tenant_id, story_id) end)
      |> Multi.run(:self_verify_check, fn _repo, %{lock: story} ->
        validate_not_self_verify(story, orchestrator_agent_id)
      end)
      |> Multi.run(:validate, fn _repo, %{lock: story} ->
        validate_verifiable(story)
      end)
      |> Multi.run(:check_review_record, fn _repo, %{lock: story} ->
        validate_review_record_exists(tenant_id, story_id, story)
      end)
      |> Multi.run(:story, fn _repo, %{lock: story} ->
        apply_verified_status(story)
      end)
      |> insert_verification_result(
        tenant_id,
        orchestrator_agent_id,
        verification_params.result,
        verification_params
      )
      |> audit_verification(tenant_id, "verified", actor_id, actor_label, orchestrator_agent_id)
      |> EventGenerator.generate_events(:webhook_events_verified, fn %{story: updated} ->
        %{
          tenant_id: tenant_id,
          event_type: "story.verified",
          project_id: updated.project_id,
          payload: %{
            "event" => "story.verified",
            "story_id" => updated.id,
            "project_id" => updated.project_id,
            "epic_id" => updated.epic_id,
            "orchestrator_agent_id" => orchestrator_agent_id,
            "summary" => verification_params.summary,
            "timestamp" => DateTime.to_iso8601(DateTime.utc_now())
          }
        }
      end)
      |> maybe_complete_epic(tenant_id, actor_id, actor_label)

    unwrap_verification_transaction(multi)
  end

  @doc """
  Rejects a story: orchestrator marks it as failing verification.

  Sets verified_status to `rejected` and creates a verification_result
  record with result=fail. Uses pessimistic locking. Can be called on
  reported_done or verified stories (allowing re-rejection).

  Requires a non-empty reason.

  ## Parameters

  - `tenant_id` -- the tenant UUID
  - `story_id` -- the story UUID
  - `params` -- map with `reason` (required), optional `findings`, `review_type`
  - `opts` -- keyword list with `:orchestrator_agent_id`, `:actor_id`, `:actor_label`

  ## Returns

  - `{:ok, %Story{}}` on success
  - `{:error, :not_found}` if story not found in tenant
  - `{:error, :invalid_transition}` if story is not reported_done or verified
  - `{:error, :reason_required}` if reason is missing or blank
  """
  @spec reject_story(Ecto.UUID.t(), Ecto.UUID.t(), map(), keyword()) ::
          {:ok, Story.t()} | {:error, atom() | {:invalid_transition, map()}}
  def reject_story(tenant_id, story_id, params, opts \\ []) do
    orchestrator_agent_id = Keyword.get(opts, :orchestrator_agent_id)
    actor_id = Keyword.get(opts, :actor_id)
    actor_label = Keyword.get(opts, :actor_label)

    reason = Map.get(params, "reason") || Map.get(params, :reason)
    rejection_params = extract_rejection_params(params)

    with :ok <- validate_reason(reason) do
      multi =
        Multi.new()
        |> Multi.run(:lock, fn _repo, _changes -> lock_story(tenant_id, story_id) end)
        |> Multi.run(:self_verify_check, fn _repo, %{lock: story} ->
          validate_not_self_verify(story, orchestrator_agent_id)
        end)
        |> Multi.run(:validate, fn _repo, %{lock: story} ->
          validate_rejectable(story)
        end)
        |> Multi.run(:story, fn _repo, %{lock: story} ->
          apply_rejected_status(story, reason)
        end)
        |> insert_verification_result(tenant_id, orchestrator_agent_id, :fail, rejection_params)
        |> audit_verification(tenant_id, "rejected", actor_id, actor_label, orchestrator_agent_id)
        |> EventGenerator.generate_events(:webhook_events_rejected, fn %{story: updated} ->
          %{
            tenant_id: tenant_id,
            event_type: "story.rejected",
            project_id: updated.project_id,
            payload: %{
              "event" => "story.rejected",
              "story_id" => updated.id,
              "project_id" => updated.project_id,
              "epic_id" => updated.epic_id,
              "orchestrator_agent_id" => orchestrator_agent_id,
              "reason" => reason,
              "findings" => rejection_params.findings,
              "timestamp" => DateTime.to_iso8601(DateTime.utc_now())
            }
          }
        end)
        |> maybe_auto_reset(tenant_id, orchestrator_agent_id)

      unwrap_verification_transaction(multi)
    end
  end

  @doc """
  Verifies all reported_done stories in an epic in a single operation.

  Finds all stories in the epic with agent_status=reported_done and
  verified_status=unverified, then verifies each one using the same
  logic as `verify_story/4`. Requires orchestrator role.

  Stories that fail verification (e.g., self-verify block) are skipped
  and reported in the errors list.

  ## Parameters

  - `tenant_id` -- the tenant UUID
  - `epic_id` -- the epic UUID
  - `params` -- map with `summary` and `review_type` (same as single verify)
  - `opts` -- keyword list with `:orchestrator_agent_id`, `:actor_id`, `:actor_label`

  ## Returns

  - `{:ok, %{verified_count: integer, skipped_count: integer, errors: [map()]}}` on success
  """
  @spec verify_all_in_epic(Ecto.UUID.t(), Ecto.UUID.t(), map(), keyword()) ::
          {:ok, map()}
  def verify_all_in_epic(tenant_id, epic_id, params, opts \\ []) do
    stories_to_verify = fetch_eligible_stories_for_verify(tenant_id, epic_id)
    results = Enum.map(stories_to_verify, &verify_single(tenant_id, &1, params, opts))

    verified = Enum.count(results, &match?({:ok, _}, &1))
    errors = results |> Enum.filter(&match?({:error, _}, &1)) |> Enum.map(&elem(&1, 1))

    {:ok,
     %{
       verified_count: verified,
       skipped_count: length(errors),
       total_eligible: length(stories_to_verify),
       errors: errors
     }}
  end

  defp fetch_eligible_stories_for_verify(tenant_id, epic_id) do
    Story
    |> where(
      [s],
      s.tenant_id == ^tenant_id and
        s.epic_id == ^epic_id and
        s.agent_status == :reported_done and
        s.verified_status == :unverified
    )
    |> AdminRepo.all()
  end

  defp verify_single(tenant_id, story, params, opts) do
    case verify_story(tenant_id, story.id, params, opts) do
      {:ok, _updated} -> {:ok, story.id}
      {:error, reason} -> {:error, %{story_id: story.id, reason: inspect(reason)}}
    end
  end

  @doc """
  Lists verification results for a story.

  ## Parameters

  - `tenant_id` -- the tenant UUID
  - `story_id` -- the story UUID

  ## Returns

  - `{:ok, [%VerificationResult{}]}` on success
  """
  @spec list_verifications(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, [VerificationResult.t()]}
  def list_verifications(tenant_id, story_id) do
    results =
      VerificationResult
      |> where([v], v.tenant_id == ^tenant_id and v.story_id == ^story_id)
      |> order_by([v], desc: v.inserted_at)
      |> AdminRepo.all()

    {:ok, results}
  end

  @doc """
  Checks if all stories in an epic are verified.

  Returns false for empty epics (zero stories).
  """
  @spec all_stories_verified?(Ecto.UUID.t(), Ecto.UUID.t()) :: boolean()
  def all_stories_verified?(tenant_id, epic_id) do
    total = count_stories_in_epic(tenant_id, epic_id)
    unverified = count_unverified_in_epic(tenant_id, epic_id)
    total > 0 and unverified == 0
  end

  # --- Orchestrator Force-Unclaim (US-7.5) ---

  @doc """
  Force-unclaims a story: orchestrator resets it to pending.

  Resets agent_status to `pending`, clears assigned_agent_id and
  assigned_at. Does NOT reset verified_status. Idempotent on
  already-pending stories. Works from any agent_status.

  ## Parameters

  - `tenant_id` -- the tenant UUID
  - `story_id` -- the story UUID
  - `opts` -- keyword list with `:orchestrator_agent_id`, `:actor_id`, `:actor_label`

  ## Returns

  - `{:ok, %Story{}}` on success
  - `{:error, :not_found}` if story not found in tenant
  """
  @spec force_unclaim_story(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, Story.t()} | {:error, atom()}
  def force_unclaim_story(tenant_id, story_id, opts \\ []) do
    orchestrator_agent_id = Keyword.get(opts, :orchestrator_agent_id)
    actor_id = Keyword.get(opts, :actor_id)
    actor_label = Keyword.get(opts, :actor_label)

    multi =
      Multi.new()
      |> Multi.run(:lock, fn _repo, _changes ->
        lock_story(tenant_id, story_id)
      end)
      |> Multi.run(:story, fn _repo, %{lock: story} ->
        # Idempotent: if already pending, return as-is without updating
        if story.agent_status == :pending do
          {:ok, story}
        else
          story
          |> Ecto.Changeset.change(%{
            agent_status: :pending,
            assigned_agent_id: nil,
            assigned_at: nil,
            reported_done_at: nil,
            reported_by_agent_id: nil
          })
          |> AdminRepo.update()
        end
      end)
      |> Audit.log_in_multi(:audit, fn %{story: updated, lock: old} ->
        %{
          tenant_id: tenant_id,
          entity_type: "story",
          entity_id: updated.id,
          action: "force_unclaimed",
          actor_type: "api_key",
          actor_id: actor_id,
          actor_label: actor_label,
          old_state: %{
            "agent_status" => to_string(old.agent_status),
            "assigned_agent_id" => old.assigned_agent_id
          },
          new_state: %{
            "agent_status" => "pending",
            "orchestrator_agent_id" => orchestrator_agent_id
          }
        }
      end)
      |> EventGenerator.generate_events(:webhook_events, fn %{story: updated, lock: old} ->
        %{
          tenant_id: tenant_id,
          event_type: "story.force_unclaimed",
          project_id: updated.project_id,
          payload: %{
            "event" => "story.force_unclaimed",
            "story_id" => updated.id,
            "project_id" => updated.project_id,
            "epic_id" => updated.epic_id,
            "old_status" => to_string(old.agent_status),
            "new_status" => "pending",
            "orchestrator_agent_id" => orchestrator_agent_id,
            "timestamp" => DateTime.to_iso8601(DateTime.utc_now())
          }
        }
      end)

    case AdminRepo.transaction(multi) do
      {:ok, %{story: updated}} -> {:ok, updated}
      {:error, :lock, reason, _} -> {:error, reason}
      {:error, :story, changeset, _} -> {:error, changeset}
    end
  end

  # --- Verification/Rejection helpers ---

  defp validate_not_self_verify(story, nil), do: {:ok, story}

  defp validate_not_self_verify(story, orchestrator_agent_id) do
    if not is_nil(story.assigned_agent_id) and story.assigned_agent_id == orchestrator_agent_id do
      {:error, :self_verify_blocked}
    else
      {:ok, story}
    end
  end

  defp validate_verifiable(story) do
    cond do
      story.agent_status != :reported_done ->
        {:error,
         {:invalid_transition,
          %{
            current_agent_status: story.agent_status,
            current_verified_status: story.verified_status,
            attempted_action: "verify",
            hint: "Story must be in 'reported_done' agent_status before it can be verified"
          }}}

      story.verified_status == :verified ->
        {:error,
         {:invalid_transition,
          %{
            current_agent_status: story.agent_status,
            current_verified_status: story.verified_status,
            attempted_action: "verify",
            hint: "Story is already verified"
          }}}

      true ->
        {:ok, story}
    end
  end

  defp validate_review_record_exists(tenant_id, story_id, story) do
    reported_done_at = story.reported_done_at

    query =
      ReviewRecord
      |> where([r], r.tenant_id == ^tenant_id and r.story_id == ^story_id)

    query =
      if reported_done_at do
        where(query, [r], r.completed_at > ^reported_done_at)
      else
        query
      end

    # Use limit 1 + order by to handle multiple review records for same story
    # (e.g., both orchestrator and forked review agent called review_complete)
    query = query |> order_by([r], desc: r.completed_at) |> limit(1)

    case AdminRepo.one(query) do
      nil ->
        {:error, :review_not_conducted}

      _record ->
        {:ok, :review_record_present}
    end
  end

  defp validate_rejectable(story) do
    if story.agent_status == :reported_done or story.verified_status == :verified do
      {:ok, story}
    else
      {:error,
       {:invalid_transition,
        %{
          current_agent_status: story.agent_status,
          current_verified_status: story.verified_status,
          attempted_action: "reject",
          hint:
            "Story must be 'reported_done' or 'verified' before it can be rejected. " <>
              "Did the agent report done first?"
        }}}
    end
  end

  defp apply_verified_status(story) do
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

  defp apply_rejected_status(story, reason) do
    now = DateTime.utc_now()

    story
    |> Ecto.Changeset.change(%{
      verified_status: :rejected,
      rejected_at: now,
      rejection_reason: reason
    })
    |> AdminRepo.update()
  end

  defp insert_verification_result(multi, tenant_id, orch_agent_id, result, params) do
    Multi.run(multi, :verification_result, fn _repo, %{lock: story} ->
      iteration = count_verifications(tenant_id, story.id) + 1

      %VerificationResult{
        tenant_id: tenant_id,
        story_id: story.id,
        orchestrator_agent_id: orch_agent_id
      }
      |> VerificationResult.create_changeset(
        Map.merge(params, %{result: result, iteration: iteration})
      )
      |> AdminRepo.insert()
    end)
  end

  defp audit_verification(multi, tenant_id, action, actor_id, actor_label, orch_agent_id) do
    Audit.log_in_multi(multi, :audit, fn %{story: updated, lock: old} ->
      %{
        tenant_id: tenant_id,
        entity_type: "story",
        entity_id: updated.id,
        action: action,
        actor_type: "api_key",
        actor_id: actor_id,
        actor_label: actor_label,
        old_state: %{"verified_status" => to_string(old.verified_status)},
        new_state: %{
          "verified_status" => to_string(updated.verified_status),
          "orchestrator_agent_id" => orch_agent_id
        }
      }
    end)
  end

  defp maybe_complete_epic(multi, tenant_id, actor_id, actor_label) do
    Multi.run(multi, :epic_completion, fn _repo, %{story: story} ->
      check_epic_completion(tenant_id, story.epic_id, actor_id, actor_label)
    end)
  end

  defp check_epic_completion(tenant_id, epic_id, actor_id, actor_label) do
    total_stories = count_stories_in_epic(tenant_id, epic_id)
    unverified_count = count_unverified_in_epic(tenant_id, epic_id)

    cond do
      # Zero-story epics never complete
      total_stories == 0 ->
        {:ok, :no_stories}

      # Not all verified yet
      unverified_count > 0 ->
        {:ok, :incomplete}

      # All verified - check if already completed (idempotent)
      epic_already_completed?(tenant_id, epic_id) ->
        {:ok, :already_completed}

      # All verified and not yet completed - fire event
      true ->
        record_epic_completion(tenant_id, epic_id, total_stories, actor_id, actor_label)
    end
  end

  defp count_stories_in_epic(tenant_id, epic_id) do
    Story
    |> where([s], s.tenant_id == ^tenant_id and s.epic_id == ^epic_id)
    |> AdminRepo.aggregate(:count, :id)
  end

  defp count_unverified_in_epic(tenant_id, epic_id) do
    Story
    |> where([s], s.tenant_id == ^tenant_id and s.epic_id == ^epic_id)
    |> where([s], s.verified_status != :verified)
    |> AdminRepo.aggregate(:count, :id)
  end

  defp epic_already_completed?(tenant_id, epic_id) do
    AuditLog
    |> where([a], a.tenant_id == ^tenant_id)
    |> where([a], a.entity_type == "epic" and a.entity_id == ^epic_id)
    |> where([a], a.action == "completed")
    |> AdminRepo.exists?()
  end

  defp record_epic_completion(tenant_id, epic_id, story_count, actor_id, actor_label) do
    epic = AdminRepo.get!(Epic, epic_id)

    payload = %{
      "event" => "epic.completed",
      "epic_id" => epic_id,
      "epic_number" => epic.number,
      "epic_title" => epic.title,
      "project_id" => epic.project_id,
      "story_count" => story_count,
      "timestamp" => DateTime.to_iso8601(DateTime.utc_now())
    }

    with {:ok, _audit} <-
           Audit.create_log_entry(tenant_id, %{
             entity_type: "epic",
             entity_id: epic_id,
             action: "completed",
             actor_type: "api_key",
             actor_id: actor_id,
             actor_label: actor_label,
             new_state: %{
               "epic_id" => epic_id,
               "epic_number" => epic.number,
               "epic_title" => epic.title,
               "project_id" => epic.project_id,
               "story_count" => story_count
             }
           }) do
      insert_events_with_delivery(tenant_id, "epic.completed", epic.project_id, payload)

      {:ok, :completed}
    end
  end

  defp unwrap_verification_transaction(multi) do
    case AdminRepo.transaction(multi) do
      # When auto-reset happened, return the reset story (non-nil means reset was performed)
      {:ok, %{auto_reset: %Story{} = reset_story}} -> {:ok, reset_story}
      {:ok, %{story: updated}} -> {:ok, updated}
      {:error, _step, {:invalid_transition, _ctx} = reason, _completed} -> {:error, reason}
      {:error, _step, reason, _completed} -> {:error, reason}
    end
  end

  defp maybe_auto_reset(multi, tenant_id, orchestrator_agent_id) do
    Multi.run(multi, :auto_reset, fn _repo, %{lock: old_story, story: rejected_story} ->
      with {:ok, tenant} <- Tenants.get_tenant(tenant_id),
           true <- Tenants.get_tenant_settings(tenant, "auto_reset_on_rejection", true) do
        perform_auto_reset(rejected_story, old_story, tenant_id, orchestrator_agent_id)
      else
        false -> {:ok, nil}
        error -> error
      end
    end)
  end

  defp perform_auto_reset(story, old_story, tenant_id, orchestrator_agent_id) do
    changeset =
      Ecto.Changeset.change(story, %{
        agent_status: :pending,
        assigned_agent_id: nil,
        assigned_at: nil,
        reported_done_at: nil
      })

    with {:ok, reset_story} <- AdminRepo.update(changeset),
         {:ok, _audit} <-
           Audit.create_log_entry(tenant_id, %{
             entity_type: "story",
             entity_id: reset_story.id,
             action: "auto_reset",
             actor_type: "system",
             actor_id: nil,
             actor_label: "system:auto_reset",
             old_state: %{
               "agent_status" => to_string(old_story.agent_status),
               "assigned_agent_id" => old_story.assigned_agent_id
             },
             new_state: %{
               "agent_status" => "pending",
               "assigned_agent_id" => nil
             }
           }),
         _events <-
           generate_auto_reset_events(
             tenant_id,
             reset_story,
             orchestrator_agent_id
           ) do
      {:ok, reset_story}
    end
  end

  defp generate_auto_reset_events(tenant_id, story, orchestrator_agent_id) do
    payload = %{
      "event" => "story.auto_reset",
      "story_id" => story.id,
      "project_id" => story.project_id,
      "epic_id" => story.epic_id,
      "reason" => "rejected",
      "orchestrator_agent_id" => orchestrator_agent_id,
      "timestamp" => DateTime.to_iso8601(DateTime.utc_now())
    }

    insert_events_with_delivery(tenant_id, "story.auto_reset", story.project_id, payload)
  end

  defp insert_events_with_delivery(tenant_id, event_type, project_id, payload) do
    require Logger

    EventGenerator.matching_webhooks(tenant_id, event_type, project_id)
    |> Enum.each(fn webhook ->
      insert_single_event_with_delivery(tenant_id, webhook, event_type, payload)
    end)
  end

  defp insert_single_event_with_delivery(tenant_id, webhook, event_type, payload) do
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

  defp extract_verification_params(params) do
    result = parse_verification_result(Map.get(params, "result") || Map.get(params, :result))

    %{
      summary: Map.get(params, "summary") || Map.get(params, :summary),
      findings: Map.get(params, "findings") || Map.get(params, :findings, %{}),
      review_type: Map.get(params, "review_type") || Map.get(params, :review_type),
      result: result
    }
  end

  defp parse_verification_result("partial"), do: :partial
  defp parse_verification_result(:partial), do: :partial
  defp parse_verification_result(_), do: :pass

  defp extract_rejection_params(params) do
    reason = Map.get(params, "reason") || Map.get(params, :reason)

    %{
      summary: reason,
      findings: Map.get(params, "findings") || Map.get(params, :findings, %{}),
      review_type: Map.get(params, "review_type") || Map.get(params, :review_type)
    }
  end

  # --- Private helpers ---

  defp lock_story(tenant_id, story_id) do
    query =
      Story
      |> where([s], s.id == ^story_id and s.tenant_id == ^tenant_id)
      |> lock("FOR UPDATE")

    case AdminRepo.one(query) do
      nil -> {:error, :not_found}
      story -> {:ok, story}
    end
  end

  # State machine: valid transitions for agent_status
  @valid_transitions %{
    pending: :contracted,
    contracted: :assigned,
    assigned: :implementing,
    implementing: :reported_done
  }

  defp validate_transition(current_status, target_status) do
    if Map.get(@valid_transitions, current_status) == target_status do
      :ok
    else
      # Return specific errors for common out-of-order transition attempts
      case {current_status, target_status} do
        {:pending, :assigned} -> {:error, :must_contract_first}
        {:pending, :implementing} -> {:error, :must_contract_first}
        {:contracted, :implementing} -> {:error, :must_claim_first}
        _ -> {:error, :invalid_transition}
      end
    end
  end

  # Returns :ok or {:error, {:invalid_transition, context}} with rich context for the caller.
  defp validate_transition_ctx(story, target_status, attempted_action) do
    case validate_transition(story.agent_status, target_status) do
      :ok ->
        :ok

      {:error, :invalid_transition} ->
        {:error,
         {:invalid_transition,
          %{
            current_agent_status: story.agent_status,
            current_verified_status: story.verified_status,
            attempted_action: attempted_action
          }}}

      other ->
        other
    end
  end

  defp validate_assigned_agent(story, agent_id) do
    if story.assigned_agent_id == agent_id do
      :ok
    else
      {:error, :not_assigned_agent}
    end
  end

  # nil agent_id: no agent identity — cannot determine self-report, allow through
  defp validate_not_self_report(_story, nil), do: :ok

  defp validate_not_self_report(story, agent_id) do
    if not is_nil(story.assigned_agent_id) and story.assigned_agent_id == agent_id do
      {:error, :self_report_blocked}
    else
      :ok
    end
  end

  # nil reviewer_agent_id: no attributable reviewer — default to rejecting.
  # The controller must enforce non-nil upstream; this is defense-in-depth
  # for any future code path that calls record_review/4 directly.
  defp validate_not_self_review(_story, nil), do: {:error, :self_review_blocked}

  defp validate_not_self_review(story, reviewer_agent_id) do
    if not is_nil(story.assigned_agent_id) and story.assigned_agent_id == reviewer_agent_id do
      {:error, :self_review_blocked}
    else
      :ok
    end
  end

  defp validate_story_implementing(%Story{agent_status: :implementing}), do: :ok

  defp validate_story_implementing(story) do
    {:error,
     {:invalid_transition,
      %{
        current_agent_status: story.agent_status,
        current_verified_status: story.verified_status,
        attempted_action: "request-review",
        hint: "Story must be in 'implementing' status to request review"
      }}}
  end

  defp check_claim_dependencies(story) do
    # Check story-level dependencies: all depends_on stories must be verified
    story_deps_unmet =
      from(sd in StoryDependency,
        join: dep in Story,
        on: dep.id == sd.depends_on_story_id,
        where: sd.story_id == ^story.id and dep.verified_status != :verified,
        select: count(sd.id)
      )
      |> AdminRepo.one()

    if story_deps_unmet > 0 do
      {:error, :dependencies_not_met}
    else
      # Check epic-level dependencies: all stories in prerequisite epics must be verified
      epic_deps_unmet =
        from(ed in EpicDependency,
          where: ed.epic_id == ^story.epic_id,
          join: prereq_story in Story,
          on: prereq_story.epic_id == ed.depends_on_epic_id,
          where: prereq_story.verified_status != :verified,
          select: count(prereq_story.id)
        )
        |> AdminRepo.one()

      if epic_deps_unmet > 0 do
        {:error, :dependencies_not_met}
      else
        {:ok, :deps_satisfied}
      end
    end
  end

  defp validate_unclaim(story, _agent_id) when story.agent_status == :pending do
    {:error, :invalid_transition}
  end

  defp validate_unclaim(story, _agent_id) when story.agent_status == :contracted do
    # Contracted stories have no assigned agent, so regular agents cannot
    # unclaim them. Only the orchestrator (via force_unclaim) can reset these.
    {:error, :not_assigned_to_you}
  end

  defp validate_unclaim(story, agent_id) do
    if story.assigned_agent_id == agent_id do
      :ok
    else
      {:error, :not_assigned_agent}
    end
  end

  defp validate_title(story, story_title) do
    if story.title == story_title do
      :ok
    else
      {:error, :title_mismatch}
    end
  end

  defp validate_ac_count(story, ac_count) do
    actual_count = length(story.acceptance_criteria || [])

    if actual_count == ac_count do
      :ok
    else
      {:error,
       {:contract_mismatch,
        %{expected_ac_count: actual_count, provided_ac_count: ac_count, field: :ac_count}}}
    end
  end

  defp maybe_validate_contract(_story, _story_title, _ac_count, true), do: :ok

  defp maybe_validate_contract(story, story_title, ac_count, false) do
    with :ok <- validate_title(story, story_title) do
      validate_ac_count(story, ac_count)
    end
  end

  defp maybe_create_artifact(multi, _tenant_id, _story_id, _agent_id, nil), do: multi

  defp maybe_create_artifact(multi, tenant_id, story_id, agent_id, params) do
    Multi.run(multi, :artifact, fn _repo, _changes ->
      changeset =
        %ArtifactReport{
          tenant_id: tenant_id,
          story_id: story_id,
          reported_by: :agent,
          reporter_agent_id: agent_id
        }
        |> ArtifactReport.create_changeset(params)

      AdminRepo.insert(changeset)
    end)
  end

  defp maybe_create_token_usage_report(multi, _tenant_id, _story_id, _agent_id, nil), do: multi

  defp maybe_create_token_usage_report(multi, tenant_id, story_id, agent_id, params) do
    alias Loopctl.TokenUsage

    Multi.run(multi, :token_usage_report, fn _repo, %{lock: story} ->
      attrs =
        params
        |> Map.put("story_id", story_id)
        |> Map.put("agent_id", agent_id)
        |> Map.put("project_id", story.project_id)

      changeset =
        %TokenUsage.Report{
          tenant_id: tenant_id,
          story_id: story_id,
          agent_id: agent_id,
          project_id: story.project_id
        }
        |> TokenUsage.Report.create_changeset(attrs)

      AdminRepo.insert(changeset)
    end)
  end

  defp maybe_audit_token_usage(multi, _tenant_id, _actor_id, _actor_label, nil), do: multi

  defp maybe_audit_token_usage(multi, tenant_id, actor_id, actor_label, _params) do
    Audit.log_in_multi(multi, :audit_token_usage, fn changes ->
      report = Map.get(changes, :token_usage_report)

      %{
        tenant_id: tenant_id,
        entity_type: "token_usage_report",
        entity_id: report.id,
        action: "created",
        actor_type: "api_key",
        actor_id: actor_id,
        actor_label: actor_label,
        new_state: %{
          "story_id" => report.story_id,
          "agent_id" => report.agent_id,
          "input_tokens" => report.input_tokens,
          "output_tokens" => report.output_tokens,
          "model_name" => report.model_name,
          "cost_millicents" => report.cost_millicents,
          "phase" => report.phase
        }
      }
    end)
  end

  defp validate_reason(nil), do: {:error, :reason_required}

  defp validate_reason(reason) when is_binary(reason) do
    if String.trim(reason) == "" do
      {:error, :reason_required}
    else
      :ok
    end
  end

  defp validate_reason(_), do: {:error, :reason_required}

  defp count_verifications(tenant_id, story_id) do
    VerificationResult
    |> where([v], v.tenant_id == ^tenant_id and v.story_id == ^story_id)
    |> AdminRepo.aggregate(:max, :iteration) || 0
  end
end
