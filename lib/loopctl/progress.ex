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
  alias Loopctl.Audit
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
end
