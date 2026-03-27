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
  alias Loopctl.Artifacts.VerificationResult
  alias Loopctl.Audit
  alias Loopctl.Audit.AuditLog
  alias Loopctl.Tenants
  alias Loopctl.WorkBreakdown.Epic
  alias Loopctl.WorkBreakdown.Story

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
          {:ok, Story.t()} | {:error, atom()}
  def contract_story(tenant_id, story_id, params, opts \\ []) do
    agent_id = Keyword.get(opts, :agent_id)
    actor_id = Keyword.get(opts, :actor_id)
    actor_label = Keyword.get(opts, :actor_label)

    story_title = Map.get(params, "story_title") || Map.get(params, :story_title)
    ac_count = Map.get(params, "ac_count") || Map.get(params, :ac_count)

    with {:ok, story} <- get_story(tenant_id, story_id),
         :ok <- validate_transition(story.agent_status, :contracted),
         :ok <- validate_title(story, story_title),
         :ok <- validate_ac_count(story, ac_count) do
      now = DateTime.utc_now()

      changeset =
        Ecto.Changeset.change(story, %{
          agent_status: :contracted,
          updated_at: now
        })

      multi =
        Multi.new()
        |> Multi.update(:story, changeset)
        |> Audit.log_in_multi(:audit, fn %{story: updated} ->
          %{
            tenant_id: tenant_id,
            entity_type: "story",
            entity_id: updated.id,
            action: "status_changed",
            actor_type: "api_key",
            actor_id: actor_id,
            actor_label: actor_label,
            old_state: %{"agent_status" => to_string(story.agent_status)},
            new_state: %{
              "agent_status" => to_string(updated.agent_status),
              "agent_id" => agent_id
            }
          }
        end)

      case AdminRepo.transaction(multi) do
        {:ok, %{story: updated}} -> {:ok, updated}
        {:error, :story, changeset, _} -> {:error, changeset}
      end
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
          {:ok, Story.t()} | {:error, atom()}
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
        case validate_transition(story.agent_status, :assigned) do
          :ok -> {:ok, story}
          error -> error
        end
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

    case AdminRepo.transaction(multi) do
      {:ok, %{story: updated}} -> {:ok, updated}
      {:error, :lock, reason, _} -> {:error, reason}
      {:error, :validate, reason, _} -> {:error, reason}
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
          {:ok, Story.t()} | {:error, atom()}
  def start_story(tenant_id, story_id, opts \\ []) do
    agent_id = Keyword.get(opts, :agent_id)
    actor_id = Keyword.get(opts, :actor_id)
    actor_label = Keyword.get(opts, :actor_label)

    with {:ok, story} <- get_story(tenant_id, story_id),
         :ok <- validate_transition(story.agent_status, :implementing),
         :ok <- validate_assigned_agent(story, agent_id) do
      changeset =
        Ecto.Changeset.change(story, %{
          agent_status: :implementing
        })

      multi =
        Multi.new()
        |> Multi.update(:story, changeset)
        |> Audit.log_in_multi(:audit, fn %{story: updated} ->
          %{
            tenant_id: tenant_id,
            entity_type: "story",
            entity_id: updated.id,
            action: "status_changed",
            actor_type: "api_key",
            actor_id: actor_id,
            actor_label: actor_label,
            old_state: %{"agent_status" => to_string(story.agent_status)},
            new_state: %{
              "agent_status" => to_string(updated.agent_status),
              "agent_id" => agent_id
            }
          }
        end)

      case AdminRepo.transaction(multi) do
        {:ok, %{story: updated}} -> {:ok, updated}
        {:error, :story, changeset, _} -> {:error, changeset}
      end
    end
  end

  @doc """
  Reports a story as done.

  Transitions agent_status from `implementing` to `reported_done`.
  Optionally accepts an artifact report that is created atomically.
  Only the assigned agent can report.

  ## Parameters

  - `tenant_id` -- the tenant UUID
  - `story_id` -- the story UUID
  - `opts` -- keyword list with `:agent_id`, `:actor_id`, `:actor_label`
  - `artifact_params` -- optional map with artifact report data

  ## Returns

  - `{:ok, %Story{}}` on success
  - `{:error, :not_found}` if story not found in tenant
  - `{:error, :invalid_transition}` if not in implementing state
  - `{:error, :not_assigned_agent}` if calling agent is not the assigned agent
  """
  @spec report_story(Ecto.UUID.t(), Ecto.UUID.t(), keyword(), map() | nil) ::
          {:ok, Story.t()} | {:error, atom()}
  def report_story(tenant_id, story_id, opts \\ [], artifact_params \\ nil) do
    agent_id = Keyword.get(opts, :agent_id)
    actor_id = Keyword.get(opts, :actor_id)
    actor_label = Keyword.get(opts, :actor_label)

    with {:ok, story} <- get_story(tenant_id, story_id),
         :ok <- validate_transition(story.agent_status, :reported_done),
         :ok <- validate_assigned_agent(story, agent_id) do
      now = DateTime.utc_now()

      changeset =
        Ecto.Changeset.change(story, %{
          agent_status: :reported_done,
          reported_done_at: now
        })

      multi =
        Multi.new()
        |> Multi.update(:story, changeset)
        |> maybe_create_artifact(tenant_id, story_id, agent_id, artifact_params)
        |> Audit.log_in_multi(:audit, fn %{story: updated} ->
          %{
            tenant_id: tenant_id,
            entity_type: "story",
            entity_id: updated.id,
            action: "status_changed",
            actor_type: "api_key",
            actor_id: actor_id,
            actor_label: actor_label,
            old_state: %{"agent_status" => to_string(story.agent_status)},
            new_state: %{
              "agent_status" => to_string(updated.agent_status),
              "reported_done_at" => to_string(now),
              "agent_id" => agent_id
            }
          }
        end)

      case AdminRepo.transaction(multi) do
        {:ok, %{story: updated}} -> {:ok, updated}
        {:error, :story, changeset, _} -> {:error, changeset}
        {:error, :artifact, changeset, _} -> {:error, changeset}
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

    with {:ok, story} <- get_story(tenant_id, story_id),
         :ok <- validate_unclaim(story, agent_id) do
      changeset =
        Ecto.Changeset.change(story, %{
          agent_status: :pending,
          assigned_agent_id: nil,
          assigned_at: nil,
          reported_done_at: nil
        })

      multi =
        Multi.new()
        |> Multi.update(:story, changeset)
        |> Audit.log_in_multi(:audit, fn %{story: updated} ->
          %{
            tenant_id: tenant_id,
            entity_type: "story",
            entity_id: updated.id,
            action: "status_changed",
            actor_type: "api_key",
            actor_id: actor_id,
            actor_label: actor_label,
            old_state: %{
              "agent_status" => to_string(story.agent_status),
              "assigned_agent_id" => story.assigned_agent_id
            },
            new_state: %{"agent_status" => "pending", "agent_id" => agent_id}
          }
        end)

      case AdminRepo.transaction(multi) do
        {:ok, %{story: updated}} -> {:ok, updated}
        {:error, :story, changeset, _} -> {:error, changeset}
      end
    end
  end

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
          {:ok, Story.t()} | {:error, atom()}
  def verify_story(tenant_id, story_id, params, opts \\ []) do
    orchestrator_agent_id = Keyword.get(opts, :orchestrator_agent_id)
    actor_id = Keyword.get(opts, :actor_id)
    actor_label = Keyword.get(opts, :actor_label)

    verification_params = extract_verification_params(params)

    multi =
      Multi.new()
      |> Multi.run(:lock, fn _repo, _changes -> lock_story(tenant_id, story_id) end)
      |> Multi.run(:validate, fn _repo, %{lock: story} ->
        validate_verifiable(story)
      end)
      |> Multi.run(:story, fn _repo, %{lock: story} ->
        apply_verified_status(story)
      end)
      |> insert_verification_result(tenant_id, orchestrator_agent_id, :pass, verification_params)
      |> audit_verification(tenant_id, "verified", actor_id, actor_label, orchestrator_agent_id)
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
          {:ok, Story.t()} | {:error, atom()}
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
        |> Multi.run(:validate, fn _repo, %{lock: story} ->
          validate_rejectable(story)
        end)
        |> Multi.run(:story, fn _repo, %{lock: story} ->
          apply_rejected_status(story, reason)
        end)
        |> insert_verification_result(tenant_id, orchestrator_agent_id, :fail, rejection_params)
        |> audit_verification(tenant_id, "rejected", actor_id, actor_label, orchestrator_agent_id)
        |> maybe_auto_reset(tenant_id)

      unwrap_verification_transaction(multi)
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
      |> order_by([v], asc: v.iteration)
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

    with {:ok, story} <- get_story(tenant_id, story_id) do
      # Idempotent: if already pending, return as-is
      if story.agent_status == :pending do
        {:ok, story}
      else
        apply_force_unclaim(story, tenant_id, orchestrator_agent_id, actor_id, actor_label)
      end
    end
  end

  defp apply_force_unclaim(story, tenant_id, orch_agent_id, actor_id, actor_label) do
    changeset =
      Ecto.Changeset.change(story, %{
        agent_status: :pending,
        assigned_agent_id: nil,
        assigned_at: nil,
        reported_done_at: nil
      })

    multi =
      Multi.new()
      |> Multi.update(:story, changeset)
      |> Audit.log_in_multi(:audit, fn %{story: updated} ->
        %{
          tenant_id: tenant_id,
          entity_type: "story",
          entity_id: updated.id,
          action: "force_unclaimed",
          actor_type: "api_key",
          actor_id: actor_id,
          actor_label: actor_label,
          old_state: %{
            "agent_status" => to_string(story.agent_status),
            "assigned_agent_id" => story.assigned_agent_id
          },
          new_state: %{
            "agent_status" => "pending",
            "orchestrator_agent_id" => orch_agent_id
          }
        }
      end)

    # NOTE(Epic 10): Webhook event for story.force_unclaimed deferred to Epic 10.

    case AdminRepo.transaction(multi) do
      {:ok, %{story: updated}} -> {:ok, updated}
      {:error, :story, changeset, _} -> {:error, changeset}
    end
  end

  # --- Verification/Rejection helpers ---

  defp validate_verifiable(story) do
    cond do
      story.agent_status != :reported_done -> {:error, :invalid_transition}
      story.verified_status == :verified -> {:error, :invalid_transition}
      true -> {:ok, story}
    end
  end

  defp validate_rejectable(story) do
    if story.agent_status == :reported_done or story.verified_status == :verified do
      {:ok, story}
    else
      {:error, :invalid_transition}
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

    # NOTE(Epic 10): Webhook event for epic.completed deferred to Epic 10.
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
    })
  end

  defp unwrap_verification_transaction(multi) do
    case AdminRepo.transaction(multi) do
      # When auto-reset happened, return the reset story (non-nil means reset was performed)
      {:ok, %{auto_reset: %Story{} = reset_story}} -> {:ok, reset_story}
      {:ok, %{story: updated}} -> {:ok, updated}
      {:error, :lock, reason, _} -> {:error, reason}
      {:error, :validate, reason, _} -> {:error, reason}
      {:error, :story, changeset, _} -> {:error, changeset}
      {:error, :verification_result, changeset, _} -> {:error, changeset}
      {:error, :auto_reset, reason, _} -> {:error, reason}
    end
  end

  defp maybe_auto_reset(multi, tenant_id) do
    Multi.run(multi, :auto_reset, fn _repo, %{lock: old_story, story: rejected_story} ->
      with {:ok, tenant} <- Tenants.get_tenant(tenant_id),
           true <- Tenants.get_tenant_settings(tenant, "auto_reset_on_rejection", true) do
        perform_auto_reset(rejected_story, old_story, tenant_id)
      else
        false -> {:ok, nil}
        error -> error
      end
    end)
  end

  defp perform_auto_reset(story, old_story, tenant_id) do
    changeset =
      Ecto.Changeset.change(story, %{
        agent_status: :pending,
        assigned_agent_id: nil,
        assigned_at: nil,
        reported_done_at: nil
      })

    case AdminRepo.update(changeset) do
      {:ok, reset_story} ->
        # Log auto_reset audit entry with actor_type=system
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
        })

        {:ok, reset_story}

      error ->
        error
    end
  end

  defp extract_verification_params(params) do
    %{
      summary: Map.get(params, "summary") || Map.get(params, :summary),
      findings: Map.get(params, "findings") || Map.get(params, :findings, %{}),
      review_type: Map.get(params, "review_type") || Map.get(params, :review_type)
    }
  end

  defp extract_rejection_params(params) do
    reason = Map.get(params, "reason") || Map.get(params, :reason)

    %{
      summary: reason,
      findings: Map.get(params, "findings") || Map.get(params, :findings, %{}),
      review_type: Map.get(params, "review_type") || Map.get(params, :review_type)
    }
  end

  # --- Private helpers ---

  defp get_story(tenant_id, story_id) do
    case AdminRepo.get_by(Story, id: story_id, tenant_id: tenant_id) do
      nil -> {:error, :not_found}
      story -> {:ok, story}
    end
  end

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
      {:error, :invalid_transition}
    end
  end

  defp validate_assigned_agent(story, agent_id) do
    if story.assigned_agent_id == agent_id do
      :ok
    else
      {:error, :not_assigned_agent}
    end
  end

  defp validate_unclaim(story, agent_id) do
    cond do
      story.agent_status == :pending ->
        {:error, :invalid_transition}

      # For contracted state, no agent is assigned yet, so any agent can unclaim
      story.agent_status == :contracted ->
        :ok

      story.assigned_agent_id != agent_id ->
        {:error, :not_assigned_agent}

      true ->
        :ok
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
      {:error, :ac_count_mismatch}
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
    |> AdminRepo.aggregate(:count, :id)
  end
end
