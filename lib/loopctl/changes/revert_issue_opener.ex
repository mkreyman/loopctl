defmodule Loopctl.Changes.RevertIssueOpener do
  @moduledoc """
  Opens the GitHub issue a chg revert of a `done` story owes (US-47.4, AC-47.4.5), from its
  `Loopctl.Changes.RevertIssues` outbox row. `Loopctl.Workers.ChangeRevertIssueWorker` is the
  caller; the shape is `Loopctl.Delivery.IssueCloser`'s.

  ## In order

  0. **Claims the row** (`RevertIssues.claim_attempt/2`), a compare-and-set on `:pending` and
     due that pushes the next attempt forward, so of two drainers exactly one proceeds.
  1. **Checks the source is still connected.** A revoked source abandons `source_revoked`.
  2. **On any attempt after the first, asks the forge for the marker**
     (`PullRequestSource.find_issue/2`, with `RevertIssues.issue_search/1`). Creating is not
     idempotent: an earlier attempt that created the issue and died before recording it left
     an issue carrying this row's marker in its body and its token in its title, and finding
     it records that issue instead of opening a second. The search reads every issue the
     credential opened since the row was written; one that reaches its page bound without
     finishing cannot confirm the issue is absent, so it DEFERS like a transient fault and
     creates nothing. The first attempt skips the read, because nothing can have opened it
     yet.
  3. **Creates the issue** and records its number.

  ## Transient versus permanent

  `Loopctl.Delivery.MergePrecondition.transient?/1`, the classification every forge drainer
  shares: transient backs the row off, permanent abandons on the first occurrence, a missing
  credential waits an hour per attempt within the same budget. A read in step 2 that fails is
  a fault like any other — never "not found", which is what would open the duplicate.

  ## Where it runs

  Nowhere in particular: a function on whatever node the sweep runs on, holding nothing.
  No database transaction is open across a forge call.
  """

  require Logger

  alias Loopctl.Changes.RevertIssue
  alias Loopctl.Changes.RevertIssues
  alias Loopctl.Delivery.MergePrecondition
  alias Loopctl.Delivery.PullRequestSource
  alias Loopctl.Verification.Credential

  @typedoc """
  `:opened` and `:abandoned` are terminal for the row; `:deferred` backed it off; `:skipped`
  means another writer moved it first.
  """
  @type outcome :: :opened | :abandoned | :deferred | :skipped

  @doc """
  One attempt at opening `row`'s issue. Returns `{outcome, retry_after}`, `retry_after` being
  the seconds the forge asked for, so the caller can halt a batch against a rate limit.
  """
  @spec open(RevertIssue.t()) :: {outcome(), pos_integer() | nil}
  def open(%RevertIssue{} = row) do
    case RevertIssues.claim_attempt(row.tenant_id, row.id) do
      {:ok, claimed} -> attempt(claimed)
      {:error, :not_pending} -> {:skipped, nil}
    end
  end

  defp attempt(%RevertIssue{} = row) do
    if RevertIssues.source_live?(row) do
      case Credential.repo(row.tenant_id, row.repo_full_name) do
        {:ok, repo} -> find_or_create(row, repo)
        {:error, reason} -> fault(row, reason)
      end
    else
      abandon(row, "source_revoked", nil)
    end
  end

  # `attempts` was bumped by the claim, so 1 is the first attempt.
  defp find_or_create(%RevertIssue{attempts: 1} = row, repo), do: create(row, repo)

  defp find_or_create(%RevertIssue{} = row, repo) do
    case PullRequestSource.find_issue(repo, RevertIssues.issue_search(row)) do
      {:ok, nil} -> create(row, repo)
      {:ok, number} -> record_opened(row, number, :found_from_earlier_attempt)
      {:error, reason} -> fault(row, reason)
    end
  end

  defp create(%RevertIssue{} = row, repo) do
    case PullRequestSource.create_issue(repo, row.title, row.body) do
      {:ok, number} -> record_opened(row, number, :opened)
      {:error, reason} -> fault(row, reason)
    end
  end

  defp record_opened(%RevertIssue{} = row, number, how) do
    case RevertIssues.mark_opened(row.tenant_id, row.id, number) do
      {:ok, _row} ->
        Logger.info(
          "RevertIssueOpener: #{how}: tenant_id=#{row.tenant_id} story_id=#{row.story_id} " <>
            "repo=#{row.repo_full_name} issue=#{number} change_id=#{row.change_id}",
          tenant_id: row.tenant_id,
          story_id: row.story_id
        )

        {:opened, nil}

      {:error, :not_pending} ->
        {:skipped, nil}
    end
  end

  defp fault(%RevertIssue{} = row, reason) do
    retry_after = MergePrecondition.retry_after(reason)

    cond do
      MergePrecondition.transient?(reason) ->
        defer(row, reason, retry_after)

      # More of the credential's issues than one attempt reads: absence is unconfirmed, so
      # wait and read again rather than create. Bounded like any transient fault.
      match?({:issue_search_inconclusive, _pages}, reason) ->
        defer(row, reason, nil)

      Credential.configuration?(reason) ->
        {outcome, _wait} = defer(row, reason, Credential.configuration_retry_seconds())
        {outcome, nil}

      true ->
        abandon(row, "permanent_forge_failure", reason)
    end
  end

  defp defer(%RevertIssue{} = row, reason, retry_after) do
    case RevertIssues.mark_transient_failure(row.tenant_id, row, reason, retry_after) do
      {:ok, %RevertIssue{status: :abandoned}} ->
        log_abandoned(row, "retries_exhausted", reason)
        {:abandoned, retry_after}

      {:ok, %RevertIssue{}} ->
        {:deferred, retry_after}

      {:error, :not_pending} ->
        {:skipped, retry_after}
    end
  end

  defp abandon(%RevertIssue{} = row, abandoned_reason, reason) do
    case RevertIssues.mark_abandoned(row.tenant_id, row.id, abandoned_reason, reason) do
      {:ok, _row} ->
        log_abandoned(row, abandoned_reason, reason)
        {:abandoned, MergePrecondition.retry_after(reason)}

      {:error, :not_pending} ->
        {:skipped, nil}
    end
  end

  # WARNING: an abandoned row is a revert of shipped work that nobody was told about through
  # the loop. Only the SHAPE of a forge reason is logged.
  defp log_abandoned(%RevertIssue{} = row, abandoned_reason, reason) do
    Logger.warning(
      "RevertIssueOpener: abandoned (#{abandoned_reason}): tenant_id=#{row.tenant_id} " <>
        "story_id=#{row.story_id} repo=#{row.repo_full_name} change_id=#{row.change_id} " <>
        "reason=#{inspect(reason)}",
      tenant_id: row.tenant_id,
      story_id: row.story_id
    )
  end
end
