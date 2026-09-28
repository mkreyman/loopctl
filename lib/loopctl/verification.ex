defmodule Loopctl.Verification do
  @moduledoc """
  US-26.4.2 — Context module for verification runs.

  Manages the lifecycle of independent re-execution runs that verify
  a story's acceptance criteria against committed code.

  ## Bounded writes

  `start_run/1`, `record_poll/2` and `complete_run/3` are the verification runner's writes to
  its own run, and each runs inside a transaction with its lock wait bounded
  (`Loopctl.Runners.Capacity.set_lock_timeout!/1`). Database contention (a lock wait that ran
  out, a statement cancelled, a lost connection) is `{:error, :busy}` rather than a raise,
  counted as `[:loopctl, :verification, :run_write_busy]`
  (`Loopctl.Delivery.Stages.answering_busy/4`, the one classification of that). A refused
  changeset is its `{:error, changeset}`, rolled back. On `{:error, :busy}` the runner waits
  and redoes the poll: nothing was written, or a lost connection committed it, which the next
  poll finds on the run.
  """

  import Ecto.Query

  require Logger

  alias Ecto.Multi
  alias Loopctl.AdminRepo
  alias Loopctl.Delivery.Stages
  alias Loopctl.Runners.Capacity
  alias Loopctl.Verification.VerificationRun
  alias Loopctl.Workers.VerificationRunnerWorker

  @doc "Creates a new verification run for a story."
  @spec create_run(Ecto.UUID.t(), Ecto.UUID.t(), map()) ::
          {:ok, VerificationRun.t()} | {:error, term()}
  def create_run(tenant_id, story_id, attrs \\ %{}) do
    %VerificationRun{tenant_id: tenant_id, story_id: story_id}
    |> VerificationRun.changeset(attrs)
    |> AdminRepo.insert()
  end

  @doc """
  Atomically creates a verification run AND enqueues its runner job.

  The run row and the Oban job are inserted in a single `Ecto.Multi`
  transaction: either both commit or neither does. This guarantees a run row is
  never left in `"pending"` with no job to execute it (and no job is ever
  enqueued for a run that failed to insert).

  Returns `{:ok, run}` or `{:error, reason}`. A raised DB exception during the
  transaction (e.g. a transient `Postgrex`/`DBConnection` error) is caught and
  returned as `{:error, exception}` — the transaction has already rolled back,
  so there is no orphaned run — letting the caller surface the failure instead
  of leaking an uncaught 500.
  """
  @spec create_run_and_enqueue(Ecto.UUID.t(), Ecto.UUID.t(), map()) ::
          {:ok, VerificationRun.t()} | {:error, term()}
  def create_run_and_enqueue(tenant_id, story_id, attrs \\ %{}) do
    run_changeset =
      %VerificationRun{tenant_id: tenant_id, story_id: story_id}
      |> VerificationRun.changeset(attrs)

    Multi.new()
    |> Multi.insert(:run, run_changeset)
    |> Oban.insert(:job, fn %{run: run} ->
      VerificationRunnerWorker.new(%{"run_id" => run.id, "tenant_id" => tenant_id})
    end)
    |> AdminRepo.transaction()
    |> case do
      {:ok, %{run: run}} -> {:ok, run}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  rescue
    exception ->
      Logger.error(
        "Verification.create_run_and_enqueue crashed for story #{story_id} " <>
          "(tenant #{tenant_id}): #{Exception.message(exception)}"
      )

      {:error, exception}
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

  @doc """
  Marks a run as started. `started_at` is written ONCE: a run re-entered after a snooze keeps
  the moment it first started (US-26.4.6). A bounded write (moduledoc, "Bounded writes").
  """
  @spec start_run(VerificationRun.t()) :: {:ok, VerificationRun.t()} | {:error, term()}
  def start_run(run) do
    bounded_write(run, "verification run start", fn ->
      update_run(run, %{status: "running", started_at: run.started_at || DateTime.utc_now()})
    end)
  end

  @doc """
  Records what one CI poll learned that the next poll of the same run needs (US-26.4.6): the
  full id of an abbreviated commit SHA (`:resolved_commit_sha`, a full git object id or
  refused), the count of transient forge faults in a row (`:ci_forge_faults`), and when the
  commit passed the once-per-run change check (`:change_checked_at`). None is castable from
  any request. A bounded write (moduledoc, "Bounded writes").
  """
  @spec record_poll(VerificationRun.t(), map()) :: {:ok, VerificationRun.t()} | {:error, term()}
  def record_poll(run, attrs) do
    bounded_write(run, "verification poll write", fn ->
      run |> poll_changeset(attrs) |> AdminRepo.update()
    end)
  end

  defp poll_changeset(run, attrs) do
    run
    |> Ecto.Changeset.change(
      Map.take(attrs, [:resolved_commit_sha, :ci_forge_faults, :change_checked_at])
    )
    |> Ecto.Changeset.validate_change(:resolved_commit_sha, fn :resolved_commit_sha, sha ->
      if Loopctl.GitSha.valid?(sha), do: [], else: [resolved_commit_sha: "must be a full id"]
    end)
    |> Ecto.Changeset.validate_number(:ci_forge_faults, greater_than_or_equal_to: 0)
  end

  @doc """
  Marks a run as completed with results: status, `completed_at` and `ac_results` in ONE
  `UPDATE`, so a write that fails leaves no part of the disposition behind. A bounded write
  (moduledoc, "Bounded writes").

  `"skipped"` (US-36.1) is a deliberate non-error terminal disposition for a run
  retired without executing (e.g. a stale backlog job age-gated before any CI call);
  it is distinct from `"error"`, which denotes a genuine failure.
  """
  @spec complete_run(VerificationRun.t(), String.t(), map()) ::
          {:ok, VerificationRun.t()} | {:error, term()}
  def complete_run(run, status, ac_results) when status in ["pass", "fail", "error", "skipped"] do
    bounded_write(run, "verification run completion", fn ->
      update_run(run, %{
        status: status,
        completed_at: DateTime.utc_now(),
        ac_results: ac_results
      })
    end)
  end

  # Moduledoc, "Bounded writes".
  defp bounded_write(run, what, write) do
    Stages.answering_busy(run.tenant_id, [:loopctl, :verification, :run_write_busy], what, fn ->
      AdminRepo.transaction(fn -> bounded(write) end)
    end)
  end

  # Inside the transaction: the lock wait bounded, and a refused write rolled back.
  defp bounded(write) do
    Capacity.set_lock_timeout!(AdminRepo)

    case write.() do
      {:ok, written} -> written
      {:error, reason} -> AdminRepo.rollback(reason)
    end
  end
end
