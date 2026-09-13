defmodule Loopctl.Delivery.PullRequestSource do
  @moduledoc """
  The facts about a real pull request that the merge precondition judges (issue #803,
  design §5 and §9). A behaviour, resolved through config-based DI, because loopctl holds
  no checkout of the target repository and must not reach the network from a context.

  `Loopctl.Delivery.MergePrecondition` resolves the implementation from
  `config :loopctl, :delivery_pull_request_source`; production is
  `Loopctl.Delivery.GitHubPullRequestSource` and the test environment is a Mox mock, so no
  test ever makes a live call.

  ## Every callback may fail, and a failure is never a pass

  Both callbacks return `{:error, reason}` for anything they could not establish —
  unreachable, rate-limited, a body that did not decode, a file list GitHub truncated. The
  precondition turns every one of them into an escalation naming the reason. There is no
  value either callback can return that lets a change merge on incomplete knowledge.

  ## `pull_request/2`

  Returns the facts of one pull request:

  - `:state` — `"open"` or `"closed"` as the forge reports it
  - `:merged?` — whether the pull request has ALREADY been merged, with `:merge_sha` set
    when it has. A resuming caller that crashed between merging and recording the merge
    asks again and adopts this answer instead of merging a second time; that is why a
    merged pull request is not an error here
  - `:head_sha`, `:merge_base_sha` — the two refs the file lists are read at
  - `:diffstat` — `%{files: n, changed_lines: n}`, the forge's own authoritative totals,
    NOT `length(files)`. A truncated file list must not shrink the diffstat that bounds it
  - `:diff` — a `Loopctl.DeliveryGates.DiffNames.parse/1`-SHAPED result, passed to
    `DiffNames.merge_input/2` untouched: `{:ok, %{files: _, renames: _}}` or
    `{:error, reason}`, which becomes Gate B's unreadable-diff marker. Every added,
    modified, deleted and renamed-to path, plus both names of every rename

  ## `repo_files/2`

  The repository's whole file list at one ref — Gate B's stale-trigger input. The
  precondition asks for it at BOTH the head and the merge base, because a pattern matching
  at one and not the other is exactly the drift the guard exists to catch.

  ## `deployments_since/3` and `contains?/3` — the post-deploy half (#803 §9)

  These two are the forge's read surface for `Loopctl.Delivery.PostDeployVerification`.
  They live on THIS behaviour, not a second client, so the whole delivery loop reaches the
  forge through one config-resolved implementation with one set of bounded timeouts and one
  rate-limit classification. (The behaviour is named for its first consumer; it is the
  delivery loop's forge reads, and a deployment is one of them.)

  **They read the DEPLOYMENT, never a workflow run's head.** Design §9: a `workflow_run`
  deploy ships the TRIGGERING run's commit while the API attributes the deploy run to
  whatever the branch head was when the run was created, so two merges minutes apart give a
  run attributed to the second that shipped the first. A deployment record's `sha` is
  written by the deploying job itself, which is the only party that knows what it checked
  out.

  **`deployments_since/3` is a PAGE, filtered by time, and both halves are load-bearing.**

  - *A page, not the newest one.* Reading only the newest made a LATER story's failed deploy
    escalate an EARLIER story that had already shipped: A merges and deploy 1 carries it, B
    merges and deploy 2 fails, and A's next sweep read deploy 2 as the whole truth. A verdict
    about one merge has to be reached from the deployment that would have CARRIED it, which
    is not always the newest one.
  - *Filtered by `since`, the moment the merge was recorded.* A deployment created BEFORE the
    merge cannot contain it, so including one is not merely wasteful — it is how the happy
    path escalated. Between a runner reporting `deployed` and the deploy job creating its
    record (a queued workflow on a cold runner: routinely 30-120s) the newest deployment is
    the PREVIOUS one, which by construction does not contain this merge, and a verifier that
    could not tell "my deploy has not started" from "something else shipped" took the
    human-only `verification_failed` edge on a healthy delivery.

  So an EMPTY list is the ordinary early answer — "nothing that could carry this merge
  exists yet" — and it is a FACT, not a failure of the call. Newest first.

  Filtering by `since` also bounds the cost: the implementation resolves each surviving
  deployment's state, and on the common early sweep there are none to resolve.

  **`contains?/3` is why verification is not sha equality.** Merges queue: a story's merge
  can be an ancestor of what is deployed rather than equal to it, and that IS shipped.
  The forge answers whether `sha` is reachable from `ref`.
  """

  alias Loopctl.DeliveryGates.DiffNames

  @type repo :: String.t()

  @type diff :: {:ok, DiffNames.parsed()} | {:error, term()}

  @type pull_request :: %{
          state: String.t(),
          merged?: boolean(),
          merge_sha: String.t() | nil,
          head_sha: String.t(),
          merge_base_sha: String.t(),
          diffstat: %{files: non_neg_integer(), changed_lines: non_neg_integer()},
          diff: diff()
        }

  @typedoc """
  One deployment of one environment.

  - `:sha` — the commit the DEPLOYMENT names, as the deploying job recorded it
  - `:state` — its LATEST status. `:pending` covers every state that has not settled
    (`queued`, `pending`, `in_progress`) and a deployment with no status at all, because
    both mean the same thing to a verifier: ask again
  - `:succeeded?` — whether `success` appears ANYWHERE in its recent status history, which
    is a different question from `state` and the one that says whether the commit shipped.
    GitHub writes `inactive` onto earlier deployments whenever a newer one succeeds
    (`auto_inactive`, which applies to any environment not flagged
    `production_environment` — and the environment name here is configurable), so a
    deployment that shipped perfectly well is routinely `inactive` by the time a sweep
    reads it. Reading `state` alone escalated those
  - `:created_at` — when the forge created the record. The verifier compares it against the
    moment the merge was recorded, so this field is what tells a deploy that has not started
    from one that shipped something else
  - `:id` — the forge's deployment id, for the escalation reason
  """
  @type deployment :: %{
          id: integer(),
          sha: String.t(),
          state: :success | :failure | :error | :inactive | :pending,
          succeeded?: boolean(),
          created_at: DateTime.t()
        }

  @doc "The facts of one pull request. See the moduledoc."
  @callback pull_request(repo(), pos_integer()) :: {:ok, pull_request()} | {:error, term()}

  @doc "Every file the repository holds at `ref`."
  @callback repo_files(repo(), String.t()) :: {:ok, [String.t()]} | {:error, term()}

  @typedoc """
  A page of deployments, NEWEST FIRST, and whether it is the whole truth.

  `incomplete` is `nil` when it is, and otherwise the reason it is not: the forge applies
  its page size BEFORE the time filter, so a page whose oldest record is still newer than
  `since` may be hiding a deployment, and a survivor count past what the implementation
  resolves states for is the same problem one layer along.

  **Incompleteness is a FACT here, never a refusal.** A caller resolves containment over
  the newest records first, and a carrying success there is definitive whatever is hidden
  below it; refusing at this layer discarded that answer and escalated a shipped story.
  Only the ABSENCE of a definitive answer may turn `incomplete` into an escalation.
  """
  @type deployment_page :: %{deployments: [deployment()], incomplete: term() | nil}

  @doc """
  The recent deployments of `environment` created at or after `since`, NEWEST FIRST.

  An empty `deployments` list is the ordinary early answer and a FACT, not a failure. See
  the moduledoc for why this is a page filtered by time rather than the newest record, and
  `t:deployment_page/0` for why an incomplete page is data rather than an error.
  """
  @callback deployments_since(repo(), String.t(), DateTime.t()) ::
              {:ok, deployment_page()} | {:error, term()}

  @doc """
  Whether `sha` is reachable from `ref` — identical to it, or an ancestor of it.

  `{:ok, true}` means the commit is IN what `ref` names. Anything the forge could not
  establish is `{:error, reason}`, and the verifier never reads that as containment.
  """
  @callback contains?(repo(), String.t(), String.t()) :: {:ok, boolean()} | {:error, term()}
end
