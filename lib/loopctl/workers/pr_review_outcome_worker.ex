defmodule Loopctl.Workers.PrReviewOutcomeWorker do
  @moduledoc """
  Reads one merged pull request's body and records its review outcome (US-50.4,
  `Loopctl.Changes.PrReviewOutcomes`). Enqueued by `Loopctl.Intake` when a `pull_request`
  webhook reports a merge, so a forge call never runs inside the webhook.

  - Unique on `(tenant_id, source_id, pr_number)` while one is pending: a redelivered webhook
    does not queue a second read. A later run replaces the row, which is the point of a re-run.
  - A forge error is `{:error, _}`: Oban retries it with its exponential backoff, up to
    `max_attempts`.
  - A source that is revoked or gone, a tenant with no credential for the repository, or a PR
    the forge says is not merged is cancelled: no retry would change the answer.
  - The body never fails the job (`Loopctl.Changes.ReviewFindings` stores what it cannot read).
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 10,
    unique: [
      keys: [:tenant_id, :source_id, :pr_number],
      states: [:available, :scheduled, :retryable],
      period: :infinity
    ]

  require Logger

  alias Loopctl.AdminRepo
  alias Loopctl.Changes.PrReviewOutcomes
  alias Loopctl.Delivery.PullRequestSource
  alias Loopctl.Intake.Source
  alias Loopctl.Verification.Credential

  @doc "The job for `pr_number` merged on `source`'s repository."
  @spec new_for(Source.t(), pos_integer()) :: Oban.Job.changeset()
  def new_for(%Source{} = source, pr_number) do
    new(%{"tenant_id" => source.tenant_id, "source_id" => source.id, "pr_number" => pr_number})
  end

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"tenant_id" => tenant_id, "source_id" => source_id, "pr_number" => pr_number}
      })
      when is_integer(pr_number) and pr_number > 0 do
    with {:ok, source} <- live_source(tenant_id, source_id),
         {:ok, %Credential{repo: repo}} <- credential(tenant_id, source),
         {:ok, facts} <- read(repo, pr_number) do
      case PrReviewOutcomes.record(source, pr_number, facts) do
        {:ok, _outcome} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def perform(%Oban.Job{}), do: {:cancel, :invalid_args}

  defp live_source(tenant_id, source_id) do
    case AdminRepo.get(Source, source_id) do
      %Source{tenant_id: ^tenant_id, revoked_at: nil} = source -> {:ok, source}
      _ -> {:cancel, :source_unavailable}
    end
  end

  defp credential(tenant_id, source) do
    case Credential.for_read(tenant_id, source.repo_full_name) do
      {:ok, credential} -> {:ok, credential}
      {:error, :credential_unavailable} -> {:cancel, :credential_unavailable}
    end
  end

  defp read(repo, pr_number) do
    case PullRequestSource.pull_request_body(repo, pr_number) do
      {:ok, %{merged?: true} = facts} ->
        {:ok, facts}

      {:ok, _not_merged} ->
        {:cancel, :not_merged}

      {:error, reason} ->
        Logger.warning(
          "pr review outcome: forge read failed pr=#{pr_number} reason=#{inspect(reason)}"
        )

        {:error, reason}
    end
  end
end
