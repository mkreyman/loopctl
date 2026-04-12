defmodule Loopctl.Verification do
  @moduledoc """
  US-26.4.2 — Context module for verification runs.

  Manages the lifecycle of independent re-execution runs that verify
  a story's acceptance criteria against committed code.
  """

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.Verification.VerificationRun

  @doc "Creates a new verification run for a story."
  @spec create_run(Ecto.UUID.t(), Ecto.UUID.t(), map()) ::
          {:ok, VerificationRun.t()} | {:error, term()}
  def create_run(tenant_id, story_id, attrs \\ %{}) do
    %VerificationRun{tenant_id: tenant_id, story_id: story_id}
    |> VerificationRun.changeset(attrs)
    |> AdminRepo.insert()
  end

  @doc "Gets a verification run by ID, tenant-scoped."
  @spec get_run(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, VerificationRun.t()} | {:error, :not_found}
  def get_run(tenant_id, run_id) do
    case AdminRepo.get_by(VerificationRun, id: run_id, tenant_id: tenant_id) do
      nil -> {:error, :not_found}
      run -> {:ok, run}
    end
  end

  @doc "Lists verification runs for a story with pagination."
  @spec list_runs(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) :: %{
          data: [VerificationRun.t()],
          meta: map()
        }
  def list_runs(tenant_id, story_id, opts \\ []) do
    limit = opts |> Keyword.get(:limit, 20) |> max(1) |> min(100)
    offset = opts |> Keyword.get(:offset, 0) |> max(0)

    base =
      from(r in VerificationRun,
        where: r.tenant_id == ^tenant_id and r.story_id == ^story_id,
        order_by: [desc: r.inserted_at]
      )

    total_count = AdminRepo.aggregate(base, :count, :id)
    data = base |> limit(^limit) |> offset(^offset) |> AdminRepo.all()

    %{data: data, meta: %{total_count: total_count, limit: limit, offset: offset}}
  end

  @doc "Updates a run's status and results."
  @spec update_run(VerificationRun.t(), map()) ::
          {:ok, VerificationRun.t()} | {:error, term()}
  def update_run(run, attrs) do
    run
    |> VerificationRun.changeset(attrs)
    |> AdminRepo.update()
  end

  @doc "Marks a run as started."
  @spec start_run(VerificationRun.t()) :: {:ok, VerificationRun.t()} | {:error, term()}
  def start_run(run) do
    update_run(run, %{status: "running", started_at: DateTime.utc_now()})
  end

  @doc "Marks a run as completed with results."
  @spec complete_run(VerificationRun.t(), String.t(), map()) ::
          {:ok, VerificationRun.t()} | {:error, term()}
  def complete_run(run, status, ac_results) when status in ["pass", "fail", "error"] do
    update_run(run, %{
      status: status,
      completed_at: DateTime.utc_now(),
      ac_results: ac_results
    })
  end
end
