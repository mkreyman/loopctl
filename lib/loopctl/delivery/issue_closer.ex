defmodule Loopctl.Delivery.IssueCloser do
  @moduledoc """
  Closes the GitHub issue a story came from, with the resolution its verdict implies
  (#803 §9, #805 item 1).

  This is the only place in loopctl that performs an outward, effectively irreversible act on
  somebody else's ticket. Everything about its shape follows from that.

  ## What it does, in order, and why that order

  0. **Checks the intake source is still connected.** A revoked source is a tenant
     disconnecting that repository; loopctl abandons with `source_revoked` rather than writing
     to it (#826 review, finding 6). `IssueClosures.record_in/5` covers a source revoked before
     the verdict; this covers one revoked after it.
  1. **READS the issue.** Closed already?
     - carrying THIS CLOSURE'S OWN resolution label — loopctl closed it, for this verdict.
       Record `:closed` and stop. This is what makes a replay a no-op even when the crash
       landed between the close and the record of it.
     - carrying anything else, including the OTHER verdict's loopctl label — not our close.
       `:abandoned` with `closed_by_other`, never retried. Re-closing an issue somebody
       already resolved would fire the reporting system's webhook and email the reporter
       about work she has already been told about.
  2. **ADDS the resolution label**, unless the issue's LIVE label list already carries it. Not
     unless our own `labelled_at` marker is set — a maintainer can remove the label between
     attempts, and trusting the marker there closes the issue unlabelled, which is precisely
     the default-text failure this feature exists to prevent (#826 review, finding 2).
  3. **POSTS the resolution text**, unless already recorded.
  4. **READS THE STATE AGAIN**, and closes only if the issue is still open. A human closing it
     between step 1 and here fired the webhook with no loopctl label on the issue, so the
     reporter already got the default text; PATCHing it closed afterwards is answered 200 by
     GitHub and would hide that entirely (#826 round 2, finding 8).
  5. **CLOSES the issue**, with `state_reason` `completed` for a shipped fix and
     `not_planned` for a report nothing was built for.

  The label goes on BEFORE the close and that ordering is the whole point of #805. The
  reporting system's webhook fires on the CLOSE and picks its resolution text by the label it
  finds; a close that arrives first is a close it reads with the default text — *"Our team has
  shipped a fix for this issue"* — which is exactly the message a `reject` must never send.

  ## At most once, and what makes it true

  Three things, and none of them alone is enough:

  - **The row.** `Loopctl.Intake.IssueClosures` holds one per story, decided by a unique
    index, written atomically with the verdict. Two verdicts cannot make two rows.
  - **The claim.** `claim_attempt/2` is a compare-and-set on `:pending` AND on the row being
    DUE, taken before the first forge call and pushing `next_attempt_at` forward — so of two
    drainers reading the same candidate, exactly one proceeds and the other is refused. The
    status test alone was not mutual exclusion at all (#826 round 2, H1): a claim leaves the
    row `:pending`, so both callers matched and both went on to comment on the reporter's
    ticket.
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

  **The forge's `retry_after` decides the wait when it is longer than the local backoff.** A
  GitHub PRIMARY rate limit resets on an hourly boundary and says so; scheduling from the
  backoff alone spent every attempt inside one window and abandoned a closure the forge had
  already told us when to retry.

  Even the transient path is bounded: `IssueClosures.max_attempts/0`. A fault that has not
  cleared by then is a token or an outage, and an operator reading `intake_issue_closures` for
  `abandoned_reason = 'retries_exhausted'` is how it surfaces — and
  `IssueClosures.requeue_abandoned/1` is how they re-drive the backlog once the cause is
  fixed, which matters because a token missing `issues: write` abandons every closure in the
  window on its first attempt.

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
  #
  # The SOURCE check comes first and costs one indexed row: revoking an intake source is a
  # tenant disconnecting a repository, and the write scope this feature added means loopctl
  # must stop labelling, commenting on and closing issues there (#826 review, finding 6).
  # `IssueClosures.record_in/5` refuses at verdict time, which covers a source already revoked
  # then; this covers one revoked between the verdict and the sweep.
  defp attempt(%IssueClosure{} = closure) do
    if IssueClosures.source_live?(closure) do
      read_issue(closure)
    else
      abandon(closure, :source_revoked, nil)
    end
  end

  defp read_issue(%IssueClosure{} = closure) do
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
  # A CLOSED issue counts as ours only when it carries THIS CLOSURE'S OWN resolution label —
  # never merely "some loopctl label" (#826 round 2, finding 7).
  #
  # The looser test recorded somebody else's close as ours whenever the label happened to be
  # one of the two. A maintainer who labels a `not_actionable` story's issue
  # `loopctl:resolution-shipped` and closes it has already made the reporting system send the
  # shipped text; reading that as our own close then recorded `:closed`, never posted the
  # not-actionable text, and left the reporter told a fix shipped for work nobody did — the
  # exact failure #805 exists to prevent, reached through the check meant to prevent it.
  #
  # A close carrying the WRONG verdict's label is therefore `closed_by_other`: it is not this
  # closure's, and re-closing it is not the remedy either.
  defp proceed(%IssueClosure{} = closure, %{state: "closed", labels: labels}) do
    %Resolution{label: own_label} = IssueClosure.resolution(closure)

    if own_label in labels do
      record_closed(closure, :already_closed_by_loopctl)
    else
      # LABEL COUNT, never the label NAMES. A label name is unbounded remote data, and this
      # reason is stored on a length-CHECKed column — echoing the names is how a decorated
      # label could make the abandon write itself fail (#826 round 1, finding 5).
      abandon(closure, :closed_by_other, {:no_matching_loopctl_label, length(labels)})
    end
  end

  defp proceed(%IssueClosure{} = closure, %{state: _open, labels: live_labels}) do
    resolution = IssueClosure.resolution(closure)

    with {:ok, closure} <- apply_label(closure, resolution, live_labels),
         {:ok, closure} <- apply_comment(closure, resolution),
         :open <- recheck_state(closure) do
      apply_close(closure, resolution)
    else
      {:fault, reason} -> fault(closure, reason)
      {:error, :not_pending} -> {:skipped, nil}
      {:closed, outcome} -> outcome
    end
  end

  # STEP 3b: READ THE STATE AGAIN before closing (#826 round 2, finding 8).
  #
  # A human closing the issue between the first read and here was invisible: their close fired
  # the reporting system's webhook with NO loopctl label on the issue yet, so the reporter got
  # the default shipped text — and loopctl then labelled, commented and PATCHed an issue that
  # was already closed. GitHub answers that 200, so the close "succeeded", `closed_by_other`
  # was never recorded, and the operator had no sign anything went wrong.
  #
  # One extra bounded call per closure, on the path that is about to make the irreversible
  # one. Both outcomes are the same classification `proceed/2` already applies to a closed
  # issue, so a close that turns out to be OURS is still recorded rather than redone.
  defp recheck_state(%IssueClosure{} = closure) do
    case source().issue(closure.repo_full_name, closure.issue_number) do
      {:ok, %{state: "closed"} = issue} -> {:closed, proceed(closure, issue)}
      {:ok, _still_open} -> :open
      {:error, reason} -> {:fault, reason}
    end
  end

  # STEP 2, GATED ON THE ISSUE'S LIVE LABELS RATHER THAN ON OUR OWN MARKER (#826 review,
  # finding 2).
  #
  # `labelled_at` records that WE put the label on; it does not say the label is still there.
  # A maintainer can remove it between attempts, and trusting the marker then produced the one
  # outcome this whole mechanism exists to prevent: attempt 1 labels and comments, the close
  # 502s, the label is removed, attempt 2 skips re-labelling and closes — and the reporting
  # system, finding no loopctl label on the close, sends its default text and tells the
  # reporter a fix shipped for something nobody built.
  #
  # The corrective data costs nothing: the closer has just READ the issue for its replay
  # check, so the live label list is already in hand. `labelled_at` stays on the row as the
  # record of when loopctl first applied it, and is no longer consulted as a gate.
  #
  # Re-applying a label that IS present would be harmless at the forge — the endpoint is
  # additive — so this test is about spending a call, not about safety. Its absence is not.
  defp apply_label(%IssueClosure{} = closure, %Resolution{label: label}, live_labels) do
    if label in live_labels do
      {:ok, closure}
    else
      case source().label_issue(closure.repo_full_name, closure.issue_number, label) do
        :ok -> IssueClosures.mark_labelled(closure.tenant_id, closure.id)
        {:error, reason} -> {:fault, reason}
      end
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

  # `retry_after` is PASSED THROUGH, not merely returned to the worker (#826 review, H1). It
  # is the forge's own statement of when its window reopens — for a PRIMARY rate limit that is
  # up to an hour out — and scheduling from the local backoff alone spent every attempt inside
  # one window the forge had already told us the end of.
  defp defer(%IssueClosure{} = closure, reason, retry_after) do
    case IssueClosures.mark_transient_failure(closure.tenant_id, closure, reason, retry_after) do
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
