defmodule Loopctl.Workers.VerificationRunnerWorker do
  @moduledoc """
  US-26.4.2 — Processes verification runs.

  Dequeues pending runs, fetches the commit SHA, and checks CI status
  via the configured CI adapter (GitHub Actions by default). Falls back
  to marking as manual-review-needed if CI is unavailable.
  """

  use Oban.Worker, queue: :verification, max_attempts: 3

  require Logger

  alias Loopctl.Verification

  @ci_adapter Application.compile_env(:loopctl, :ci_adapter, Loopctl.Verification.GitHubActions)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"run_id" => run_id, "tenant_id" => tenant_id}}) do
    case Verification.get_run(tenant_id, run_id) do
      {:ok, run} ->
        case Verification.start_run(run) do
          {:ok, started} -> execute_verification(started, tenant_id)
          {:error, reason} -> {:error, reason}
        end

      {:error, :not_found} ->
        Logger.warning("VerificationRunner: run #{run_id} not found")
        :ok
    end
  end

  defp execute_verification(run, tenant_id) do
    Logger.info("VerificationRunner: executing run #{run.id} for story #{run.story_id}")

    if run.commit_sha do
      check_ci_status(run, tenant_id)
    else
      {:ok, _} = Verification.complete_run(run, "error", %{"reason" => "no_commit_sha"})
      :ok
    end
  rescue
    error ->
      Logger.error("VerificationRunner: run #{run.id} failed: #{Exception.message(error)}")
      Verification.complete_run(run, "error", %{"error" => Exception.message(error)})
      {:error, Exception.message(error)}
  end

  defp check_ci_status(run, tenant_id) do
    import Ecto.Query

    repo_url =
      from(s in "stories",
        join: p in "projects",
        on: s.project_id == p.id,
        where: s.id == ^run.story_id and s.tenant_id == ^tenant_id,
        select: p.repo_url,
        limit: 1
      )
      |> Loopctl.AdminRepo.one()

    if repo_url do
      do_ci_check(run, repo_url)
    else
      {:ok, _} = Verification.complete_run(run, "error", %{"reason" => "no_repo_url"})
      :ok
    end
  end

  defp do_ci_check(run, repo_url) do
    case @ci_adapter.get_status(repo_url, run.commit_sha) do
      {:ok, %{conclusion: "success"}} ->
        {:ok, _} = Verification.complete_run(run, "pass", %{"source" => "ci"})
        :ok

      {:ok, %{conclusion: "failure"}} ->
        {:ok, _} = Verification.complete_run(run, "fail", %{"source" => "ci"})
        :ok

      {:ok, %{status: "in_progress"}} ->
        {:snooze, 60}

      {:ok, %{conclusion: other}} ->
        Logger.warning("VerificationRunner: unexpected CI conclusion: #{inspect(other)}")

        {:ok, _} =
          Verification.complete_run(run, "error", %{"ci_conclusion" => other || "unknown"})

        :ok

      {:error, reason} ->
        Logger.warning("VerificationRunner: CI check failed: #{inspect(reason)}")
        {:ok, _} = Verification.complete_run(run, "error", %{"ci_error" => inspect(reason)})
        :ok
    end
  end
end
