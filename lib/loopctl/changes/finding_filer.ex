defmodule Loopctl.Changes.FindingFiler do
  @moduledoc """
  Performs one `chg_finding_actions` outbox row on GitHub (US-51.1).
  `Loopctl.Workers.ChgFindingActionWorker` is the caller; the shape is
  `Loopctl.Changes.RevertIssueOpener`'s.

  ## `:open`, in order

  0. **Claims the row** (`Findings.claim_attempt/2`), a compare-and-set on `:pending` and due,
     so of two drainers exactly one proceeds.
  1. **Checks the source is still connected.** A revoked source abandons `source_revoked`.
  2. **Finds the issue an earlier attempt made.** An action that already recorded its issue
     number goes straight to step 4. Otherwise, on any attempt after the first, it asks the
     forge for the marker (`Findings.issue_search/1`): an attempt that created the issue and
     died before recording it left the marker in its body. A search that cannot confirm
     absence defers and creates nothing. The first attempt skips the read.
  3. **Creates the issue** and records its number on the row at once
     (`Findings.record_issue/3`).
  4. **Labels it** `chg-loop` (additive and idempotent at the forge) and marks the row done,
     which also gives the finding its issue number.

  ## `:close`, `:reopen`, `:escalate` (US-51.2)

  Each is a comment on the finding's issue plus one forge state change: close it
  (`:completed`), reopen it, or add the `chg-loop-escalated` label. A retry after a partial
  attempt may post the comment twice; it never acts on a second issue. A reopen the forge
  refuses for good files the finding again (`Findings.refile/2`).

  ## Transient versus permanent

  `Loopctl.Delivery.MergePrecondition.transient?/1`, the classification every forge drainer
  shares: transient backs the row off, permanent abandons on the first occurrence, a missing
  credential waits an hour per attempt within the same budget.

  No database transaction is open across a forge call.
  """

  require Logger

  alias Loopctl.Changes.FindingAction
  alias Loopctl.Changes.Findings
  alias Loopctl.Delivery.MergePrecondition
  alias Loopctl.Delivery.PullRequestSource
  alias Loopctl.Verification.Credential

  @type outcome :: :done | :abandoned | :deferred | :skipped

  @doc """
  One attempt at `action`. Returns `{outcome, retry_after}`, `retry_after` being the seconds
  the forge asked for, so the caller can halt a batch against a rate limit.
  """
  @spec perform(FindingAction.t()) :: {outcome(), pos_integer() | nil}
  def perform(%FindingAction{} = action) do
    case Findings.claim_attempt(action.tenant_id, action.id) do
      {:ok, claimed} -> attempt(claimed)
      {:error, :not_pending} -> {:skipped, nil}
    end
  end

  defp attempt(%FindingAction{} = action) do
    if Findings.source_live?(action) do
      case Credential.repo(action.tenant_id, action.repo_full_name) do
        {:ok, repo} -> act(action, repo)
        {:error, reason} -> fault(action, reason)
      end
    else
      abandon(action, "source_revoked", nil)
    end
  end

  defp act(%FindingAction{action: :open, issue_number: n} = action, repo) when is_integer(n),
    do: label_and_finish(action, repo)

  # `attempts` was bumped by the claim, so 1 is the first attempt.
  defp act(%FindingAction{action: :open, attempts: 1} = action, repo), do: create(action, repo)

  defp act(%FindingAction{action: :open} = action, repo) do
    case PullRequestSource.find_issue(repo, Findings.issue_search(action)) do
      {:ok, nil} -> create(action, repo)
      {:ok, number} -> record_and_label(action, repo, number)
      {:error, reason} -> fault(action, reason)
    end
  end

  # US-51.2. Each act is a comment plus one forge state change, and each half is idempotent
  # at the forge except the comment, which a retry may post twice: a duplicate comment is the
  # accepted cost, never a duplicate issue.
  defp act(%FindingAction{action: :close} = action, repo) do
    with :ok <- PullRequestSource.comment_issue(repo, action.issue_number, action.body),
         :ok <- PullRequestSource.close_issue(repo, action.issue_number, :completed) do
      finish(action)
    else
      {:error, reason} -> fault(action, reason)
    end
  end

  defp act(%FindingAction{action: :reopen} = action, repo) do
    case PullRequestSource.reopen_issue(repo, action.issue_number) do
      :ok ->
        case PullRequestSource.comment_issue(repo, action.issue_number, action.body) do
          :ok -> finish(action)
          {:error, reason} -> fault(action, reason)
        end

      {:error, reason} ->
        reopen_fault(action, reason)
    end
  end

  defp act(%FindingAction{action: :escalate} = action, repo) do
    with :ok <- PullRequestSource.comment_issue(repo, action.issue_number, action.body),
         :ok <-
           PullRequestSource.label_issue(repo, action.issue_number, Findings.escalated_label()) do
      finish(action)
    else
      {:error, reason} -> fault(action, reason)
    end
  end

  # A reopen the forge refused for good (the issue was deleted or transferred) files the
  # finding again rather than abandoning the problem.
  defp reopen_fault(%FindingAction{} = action, reason) do
    if permanent?(reason) do
      case Findings.refile(action, reason) do
        {:ok, _abandoned} ->
          log_abandoned(action, "reopen_refused_refiled", reason)
          {:abandoned, nil}

        {:error, :not_pending} ->
          {:skipped, nil}
      end
    else
      fault(action, reason)
    end
  end

  defp permanent?(reason),
    do:
      not MergePrecondition.transient?(reason) and not Credential.configuration?(reason) and
        not match?({:issue_search_inconclusive, _}, reason)

  defp create(%FindingAction{} = action, repo) do
    case PullRequestSource.create_issue(repo, action.title, action.body) do
      {:ok, number} -> record_and_label(action, repo, number)
      {:error, reason} -> fault(action, reason)
    end
  end

  defp record_and_label(%FindingAction{} = action, repo, number) do
    case Findings.record_issue(action.tenant_id, action.id, number) do
      {:ok, recorded} -> label_and_finish(recorded, repo)
      {:error, :not_pending} -> {:skipped, nil}
    end
  end

  defp label_and_finish(%FindingAction{} = action, repo) do
    case PullRequestSource.label_issue(repo, action.issue_number, Findings.label()) do
      :ok -> finish(action)
      {:error, reason} -> fault(action, reason)
    end
  end

  defp finish(%FindingAction{} = action) do
    case Findings.mark_done(action) do
      {:ok, _done} ->
        Logger.info(
          "FindingFiler: #{action.action} done: tenant_id=#{action.tenant_id} " <>
            "finding_id=#{action.finding_id} repo=#{action.repo_full_name} " <>
            "issue=#{action.issue_number}",
          tenant_id: action.tenant_id
        )

        {:done, nil}

      {:error, :not_pending} ->
        {:skipped, nil}
    end
  end

  defp fault(%FindingAction{} = action, reason) do
    retry_after = MergePrecondition.retry_after(reason)

    cond do
      MergePrecondition.transient?(reason) ->
        defer(action, reason, retry_after)

      match?({:issue_search_inconclusive, _pages}, reason) ->
        defer(action, reason, nil)

      Credential.configuration?(reason) ->
        {outcome, _wait} = defer(action, reason, Credential.configuration_retry_seconds())
        {outcome, nil}

      true ->
        abandon(action, "permanent_forge_failure", reason)
    end
  end

  defp defer(%FindingAction{} = action, reason, retry_after) do
    case Findings.mark_transient_failure(action.tenant_id, action, reason, retry_after) do
      {:ok, %FindingAction{status: :abandoned}} ->
        log_abandoned(action, "retries_exhausted", reason)
        {:abandoned, retry_after}

      {:ok, %FindingAction{}} ->
        {:deferred, retry_after}

      {:error, :not_pending} ->
        {:skipped, retry_after}
    end
  end

  defp abandon(%FindingAction{} = action, abandoned_reason, reason) do
    case Findings.mark_abandoned(action.tenant_id, action.id, abandoned_reason, reason) do
      {:ok, _row} ->
        log_abandoned(action, abandoned_reason, reason)
        {:abandoned, MergePrecondition.retry_after(reason)}

      {:error, :not_pending} ->
        {:skipped, nil}
    end
  end

  # WARNING: an abandoned action is a problem the loop found and nobody was told about.
  defp log_abandoned(%FindingAction{} = action, abandoned_reason, reason) do
    Logger.warning(
      "FindingFiler: abandoned #{action.action} (#{abandoned_reason}): " <>
        "tenant_id=#{action.tenant_id} finding_id=#{action.finding_id} " <>
        "repo=#{action.repo_full_name} reason=#{inspect(reason)}",
      tenant_id: action.tenant_id
    )
  end
end
