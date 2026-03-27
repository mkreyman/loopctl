defmodule Loopctl.Artifacts do
  @moduledoc """
  Context module for artifact reports and verification results.

  Artifact reports record what an agent or orchestrator found after a story
  was implemented -- files, migrations, schemas, test results, etc.

  Verification results record the orchestrator's independent assessment of a
  story, building an immutable history of verification attempts.

  All operations are tenant-scoped and include audit logging via `Ecto.Multi`.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias Loopctl.AdminRepo
  alias Loopctl.Artifacts.ArtifactReport
  alias Loopctl.Artifacts.VerificationResult
  alias Loopctl.Audit

  # --- Artifact Reports ---

  @doc """
  Creates an artifact report for a story.

  The `tenant_id`, `story_id`, `reported_by`, and `reporter_agent_id` are
  set programmatically. The caller provides artifact details via `attrs`.

  ## Parameters

  - `tenant_id` -- the tenant UUID
  - `story_id` -- the story UUID
  - `attrs` -- map with `artifact_type` (required), optional `path`, `exists`, `details`
  - `opts` -- keyword list with `:agent_id`, `:reported_by`, `:actor_id`, `:actor_label`

  ## Returns

  - `{:ok, %ArtifactReport{}}` on success
  - `{:error, changeset}` on validation failure
  """
  @spec create_artifact_report(Ecto.UUID.t(), Ecto.UUID.t(), map(), keyword()) ::
          {:ok, ArtifactReport.t()} | {:error, Ecto.Changeset.t()}
  def create_artifact_report(tenant_id, story_id, attrs, opts \\ []) do
    agent_id = Keyword.get(opts, :agent_id)
    reported_by = Keyword.get(opts, :reported_by, :agent)
    actor_id = Keyword.get(opts, :actor_id)
    actor_label = Keyword.get(opts, :actor_label)

    changeset =
      %ArtifactReport{
        tenant_id: tenant_id,
        story_id: story_id,
        reported_by: reported_by,
        reporter_agent_id: agent_id
      }
      |> ArtifactReport.create_changeset(attrs)

    multi =
      Multi.new()
      |> Multi.insert(:artifact_report, changeset)
      |> Audit.log_in_multi(:audit, fn %{artifact_report: report} ->
        %{
          tenant_id: tenant_id,
          entity_type: "artifact_report",
          entity_id: report.id,
          action: "created",
          actor_type: "api_key",
          actor_id: actor_id,
          actor_label: actor_label,
          new_state: %{
            "story_id" => story_id,
            "artifact_type" => report.artifact_type,
            "path" => report.path,
            "exists" => report.exists,
            "reported_by" => to_string(report.reported_by),
            "reporter_agent_id" => agent_id
          }
        }
      end)

    case AdminRepo.transaction(multi) do
      {:ok, %{artifact_report: report}} -> {:ok, report}
      {:error, :artifact_report, changeset, _} -> {:error, changeset}
    end
  end

  @doc """
  Lists artifact reports for a story with optional pagination.

  ## Parameters

  - `tenant_id` -- the tenant UUID
  - `story_id` -- the story UUID
  - `opts` -- keyword list with `:page` (default 1), `:page_size` (default 20, max 100)

  ## Returns

  `{:ok, %{data: [%ArtifactReport{}], total: integer, page: integer, page_size: integer}}`
  """
  @spec list_artifact_reports(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok,
           %{
             data: [ArtifactReport.t()],
             total: non_neg_integer(),
             page: pos_integer(),
             page_size: pos_integer()
           }}
  def list_artifact_reports(tenant_id, story_id, opts \\ []) do
    page = max(Keyword.get(opts, :page, 1), 1)
    page_size = opts |> Keyword.get(:page_size, 20) |> max(1) |> min(100)
    offset = (page - 1) * page_size

    base_query =
      ArtifactReport
      |> where([a], a.tenant_id == ^tenant_id and a.story_id == ^story_id)

    total = AdminRepo.aggregate(base_query, :count, :id)

    reports =
      base_query
      |> order_by([a], asc: a.inserted_at)
      |> limit(^page_size)
      |> offset(^offset)
      |> AdminRepo.all()

    {:ok, %{data: reports, total: total, page: page, page_size: page_size}}
  end

  # --- Verification Results ---

  @doc """
  Lists verification results for a story with optional pagination.

  ## Parameters

  - `tenant_id` -- the tenant UUID
  - `story_id` -- the story UUID
  - `opts` -- keyword list with `:page` (default 1), `:page_size` (default 20, max 100)

  ## Returns

  `{:ok, %{data: [%VerificationResult{}], total: integer, page: integer, page_size: integer}}`
  """
  @spec list_verifications(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok,
           %{
             data: [VerificationResult.t()],
             total: non_neg_integer(),
             page: pos_integer(),
             page_size: pos_integer()
           }}
  def list_verifications(tenant_id, story_id, opts \\ []) do
    page = max(Keyword.get(opts, :page, 1), 1)
    page_size = opts |> Keyword.get(:page_size, 20) |> max(1) |> min(100)
    offset = (page - 1) * page_size

    base_query =
      VerificationResult
      |> where([v], v.tenant_id == ^tenant_id and v.story_id == ^story_id)

    total = AdminRepo.aggregate(base_query, :count, :id)

    results =
      base_query
      |> order_by([v], asc: v.iteration)
      |> limit(^page_size)
      |> offset(^offset)
      |> AdminRepo.all()

    {:ok, %{data: results, total: total, page: page, page_size: page_size}}
  end

  @doc """
  Gets a single verification result by ID, scoped to a tenant.

  ## Parameters

  - `tenant_id` -- the tenant UUID
  - `verification_id` -- the verification result UUID

  ## Returns

  - `{:ok, %VerificationResult{}}` if found
  - `{:error, :not_found}` if not found or belongs to another tenant
  """
  @spec get_verification(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, VerificationResult.t()} | {:error, :not_found}
  def get_verification(tenant_id, verification_id) do
    case AdminRepo.get_by(VerificationResult, id: verification_id, tenant_id: tenant_id) do
      nil -> {:error, :not_found}
      result -> {:ok, result}
    end
  end

  @doc """
  Counts the total number of verification results for a story.

  Used to provide iteration_count in story responses.

  ## Parameters

  - `tenant_id` -- the tenant UUID
  - `story_id` -- the story UUID

  ## Returns

  A non-negative integer.
  """
  @spec count_verifications(Ecto.UUID.t(), Ecto.UUID.t()) :: non_neg_integer()
  def count_verifications(tenant_id, story_id) do
    VerificationResult
    |> where([v], v.tenant_id == ^tenant_id and v.story_id == ^story_id)
    |> AdminRepo.aggregate(:count, :id)
  end
end
