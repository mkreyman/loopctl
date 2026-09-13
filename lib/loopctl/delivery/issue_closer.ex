defmodule Loopctl.Delivery.IssueCloser do
  @moduledoc """
  Closes the GitHub issue a story came from, with the resolution its verdict implies
  (#803 §9, #805 item 1).

  This is the only place in loopctl that performs an outward, effectively irreversible act on
  somebody else's ticket. Everything about its shape follows from that.

  ## What it does, in order, and why that order

  1. **READS the issue.** Closed already?
     - carrying one of `Loopctl.Delivery.Resolution.labels/0` — loopctl closed it. Record
       `:closed` and stop. This is what makes a replay a no-op even when the crash landed
       between the close and the record of it.
     - carrying none — a HUMAN closed it. `:abandoned` with `closed_by_other`, never retried.
       Re-closing an issue somebody already resolved would fire the reporting system's
       webhook and email the reporter about work she has already been told about.
  2. **ADDS the resolution label**, unless already recorded.
  3. **POSTS the resolution text**, unless already recorded.
  4. **CLOSES the issue**, with `state_reason` `completed` for a shipped fix and
     `not_planned` for a report nothing was built for.

  The label goes on BEFORE the close and that ordering is the whole point of #805. The
  reporting system's webhook fires on the CLOSE and picks its resolution text by the label it
  finds; a close that arrives first is a close it reads with the default text — *"Our team has
  shipped a fix for this issue"* — which is exactly the message a `reject` must never send.

  ## At most once, and what makes it true

  Three things, and none of them alone is enough:

  - **The row.** `Loopctl.Intake.IssueClosures` holds one per story, decided by a unique
    index, written atomically with the verdict. Two verdicts cannot make two rows.
  - **The claim.** `claim_attempt/2` is a compare-and-set on `:pending` taken before the
    first forge call, so two drainers reading the same candidate cannot both proceed.
  - **The read.** Step 1 above. The claim and the row cover everything except a crash between
    a successful close and the record of it; asking GitHub what it currently says covers that
    one.

  Steps 2 and 3 additionally carry their own markers, so a crash inside the sequence redoes at
  most the step it died in. A duplicated label is a no-op at the forge. A duplicated comment
  is a duplicated comment — visible, harmless, and the accepted cost of not holding a
  transaction across four network calls.

  ## Transient versus permanent

  `Loopctl.Delivery.MergePrecondition.transient?/1` — the SAME classification the merge gate
  and the post-deploy verifier use, not a third opinion about what a GitHub 403 means. A
  transient fault backs the row off and leaves it `:pending`; a permanent one abandons it on
  the first occurrence, because a 404, a 401, or a 403 whose headers do not say "rate limit"
  is the forge's final answer and retrying it is a loop.

  Even the transient path is bounded: `IssueClosures.max_attempts/0`. A fault that has not
  cleared by then is a token or an outage, and an operator reading `intake_issue_closures` for
  `abandoned_reason = 'retries_exhausted'` is how it surfaces.

  ## Where it runs, and how it resumes

  Nowhere in particular — a function on whatever node the sweep runs on, owning no process and
  caching nothing. `Loopctl.Workers.IntakeIssueCloseWorker` is the caller. A restart loses
  nothing: every fact is on the row, whose markers say exactly how far the last attempt got.

  ## Partitions and slow connections

  A forge loopctl cannot reach is `{:github_unreachable, _}`, which is transient: the row
  backs off and the next sweep asks again. Nothing is decided while the forge is unreachable,
  and nothing is assumed about the issue's state.

  Every call carries `Loopctl.Delivery.GitHubPullRequestSource`'s bounded connect and receive
  timeouts with no retries, so the worst case for one closure is four bounded calls.
  **No database transaction is open across any of them** — each marker is its own short
  write between calls.
  """

  require Logger

  alias Loopctl.Delivery.MergePrecondition
  alias Loopctl.Delivery.Resolution
  alias Loopctl.Intake.IssueClosure
  alias Loopctl.Intake.IssueClosures

  @typedoc """
  What one attempt did.

  `:closed` and `:abandoned` are terminal for the row. `:deferred` means a transient fault
  backed it off — the next sweep asks again. `:skipped` means another writer had already
  moved the row out of `:pending` between the candidate read and the claim.
  """
  @type outcome :: :closed | :abandoned | :deferred | :skipped

  @doc """
  Runs one attempt at closing `closure`'s issue.

  Returns `{outcome, retry_after}` where `retry_after` is the seconds the forge asked for when
  it said so at all, and `nil` otherwise. The caller halts a batch on a non-nil value: the
  remaining candidates would ask a forge that has already said it is out of quota.

  Safe to call on any row. A row that is not `:pending` is `:skipped` without a single forge
  call.
  """
  @spec close(IssueClosure.t()) :: {outcome(), pos_integer() | nil}
  def close(%IssueClosure{} = closure) do
    case IssueClosures.claim_attempt(closure.tenant_id, closure.id) do
      {:ok, claimed} -> attempt(claimed)
      {:error, :not_pending} -> {:skipped, nil}
    end
  end

  # The read that makes a replay safe, and the three writes it guards.
  defp attempt(%IssueClosure{} = closure) do
    case source().issue(closure.repo_full_name, closure.issue_number) do
      {:ok, issue} -> proceed(closure, issue)
      {:error, reason} -> fault(closure, reason)
    end
  end

  # A CLOSED issue is not ours to close again, and which of the two cases it is decides
  # whether that is success or a stop.
  #
  # `Resolution.for_labels/1` is the reverse of the mapping the verdict came from: a non-nil
  # answer means the close carries one of loopctl's labels, so loopctl made it. It does NOT
  # have to be for the same verdict — a story whose verdict somehow changed after a close
  # still must not be closed twice, and the record we want either way is that the issue is
  # closed with loopctl's resolution on it.
  defp proceed(%IssueClosure{} = closure, %{state: "closed", labels: labels}) do
    case Resolution.for_labels(labels) do
      %Resolution{} -> record_closed(closure, :already_closed_by_loopctl)
      nil -> abandon(closure, :closed_by_other, {:issue_closed_without_loopctl_label, labels})
    end
  end

  defp proceed(%IssueClosure{} = closure, %{state: _open}) do
    resolution = IssueClosure.resolution(closure)

    with {:ok, closure} <- apply_label(closure, resolution),
         {:ok, closure} <- apply_comment(closure, resolution) do
      apply_close(closure, resolution)
    else
      {:fault, reason} -> fault(closure, reason)
      {:error, :not_pending} -> {:skipped, nil}
    end
  end

  # STEP 2. Additive at the forge and idempotent, so the marker is an optimisation rather than
  # the safety property — but it also means a run that already labelled and then failed at the
  # comment does not spend a call re-labelling.
  defp apply_label(%IssueClosure{labelled_at: %DateTime{}} = closure, _resolution),
    do: {:ok, closure}

  defp apply_label(%IssueClosure{} = closure, %Resolution{label: label}) do
    case source().label_issue(closure.repo_full_name, closure.issue_number, label) do
      :ok -> IssueClosures.mark_labelled(closure.tenant_id, closure.id)
      {:error, reason} -> {:fault, reason}
    end
  end

  # STEP 3. The one call here that is NOT idempotent at the forge, which is exactly why its
  # marker is load-bearing rather than an optimisation: without it every transient failure at
  # step 4 would add another copy of the resolution to the reporter's ticket.
  defp apply_comment(%IssueClosure{commented_at: %DateTime{}} = closure, _resolution),
    do: {:ok, closure}

  defp apply_comment(%IssueClosure{} = closure, %Resolution{resolution_notes: notes})
       when is_binary(notes) do
    case source().comment_issue(closure.repo_full_name, closure.issue_number, notes) do
      :ok -> IssueClosures.mark_commented(closure.tenant_id, closure.id)
      {:error, reason} -> {:fault, reason}
    end
  end

  # A verdict with no text is not one that closes — `Resolution` gives `resolution_notes: nil`
  # only to `:escalated`, which never produces a row — so this clause is a fail-safe, not a
  # path. Skipping the comment is the right fail-safe: the LABEL is what the reporting system
  # binds to, so the close still says the right thing.
  defp apply_comment(%IssueClosure{} = closure, %Resolution{}), do: {:ok, closure}

  # STEP 4. The outward act. Everything above exists so that this happens at most once.
  defp apply_close(%IssueClosure{} = closure, %Resolution{} = resolution) do
    reason = state_reason(resolution)

    case source().close_issue(closure.repo_full_name, closure.issue_number, reason) do
      :ok -> record_closed(closure, :closed)
      {:error, forge_reason} -> fault(closure, forge_reason)
    end
  end

  # GitHub's own vocabulary for WHY an issue closed, which shows in its UI next to the closed
  # marker. It is a second, weaker copy of the same distinction the label carries — a reader
  # looking at the issue rather than at the resolution email still sees that nothing was built
  # for a rejected report.
  defp state_reason(%Resolution{verdict: :shipped}), do: :completed
  defp state_reason(%Resolution{verdict: :not_actionable}), do: :not_planned

  defp record_closed(%IssueClosure{} = closure, how) do
    case IssueClosures.mark_closed(closure.tenant_id, closure.id) do
      {:ok, _row} ->
        Logger.info(
          "IssueCloser: #{how}: tenant_id=#{closure.tenant_id} story_id=#{closure.story_id} " <>
            "repo=#{closure.repo_full_name} issue=#{closure.issue_number} " <>
            "verdict=#{closure.verdict}",
          tenant_id: closure.tenant_id,
          story_id: closure.story_id
        )

        {:closed, nil}

      # Another writer moved the row while this attempt ran. The issue is closed either way,
      # and whichever writer got there recorded it; reporting `:skipped` rather than `:closed`
      # keeps the tally honest about which attempt did the work.
      {:error, :not_pending} ->
        {:skipped, nil}
    end
  end

  # A TRANSIENT fault decides nothing and is not a verdict about the issue: back the row off
  # and ask again. A PERMANENT one is the forge's final answer, so retrying it is a loop with
  # nobody told — it abandons on the first occurrence and the row is what tells an operator.
  defp fault(%IssueClosure{} = closure, reason) do
    retry_after = MergePrecondition.retry_after(reason)

    if MergePrecondition.transient?(reason) do
      defer(closure, reason, retry_after)
    else
      abandon(closure, {:permanent_forge_failure, reason}, reason)
    end
  end

  defp defer(%IssueClosure{} = closure, reason, retry_after) do
    case IssueClosures.mark_transient_failure(closure.tenant_id, closure, reason) do
      # The bound converted it: the row is abandoned, and this is the one path that reaches
      # `:abandoned` from a transient fault.
      {:ok, %IssueClosure{status: :abandoned}} ->
        log_abandoned(closure, :retries_exhausted, reason)
        {:abandoned, retry_after}

      {:ok, %IssueClosure{}} ->
        {:deferred, retry_after}

      {:error, :not_pending} ->
        {:skipped, retry_after}
    end
  end

  defp abandon(%IssueClosure{} = closure, abandon_reason, reason) do
    case IssueClosures.mark_abandoned(closure.tenant_id, closure.id, abandon_reason, reason) do
      {:ok, _row} ->
        log_abandoned(closure, abandon_reason, reason)
        {:abandoned, MergePrecondition.retry_after(reason)}

      {:error, :not_pending} ->
        {:skipped, nil}
    end
  end

  # WARNING, not info: an abandoned closure means a reporter is never told what happened to
  # her issue by this loop, and nothing downstream retries it. Only the SHAPE of the forge
  # reason is logged, never a response body.
  defp log_abandoned(%IssueClosure{} = closure, abandon_reason, reason) do
    Logger.warning(
      "IssueCloser: abandoned (#{inspect(abandon_reason)}): tenant_id=#{closure.tenant_id} " <>
        "story_id=#{closure.story_id} repo=#{closure.repo_full_name} " <>
        "issue=#{closure.issue_number} verdict=#{closure.verdict} reason=#{inspect(reason)}",
      tenant_id: closure.tenant_id,
      story_id: closure.story_id
    )
  end

  defp source do
    Application.get_env(
      :loopctl,
      :delivery_pull_request_source,
      Loopctl.Delivery.GitHubPullRequestSource
    )
  end
end
