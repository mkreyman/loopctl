defmodule Loopctl.Delivery.PostDeployVerification do
  @moduledoc """
  The control-side check that a merged story is actually RUNNING (issue #803 §3 and §9,
  issue #805 item 2).

  A story reaches `deployed` and stops. `Loopctl.Delivery.StageMachine`'s runner allowlist
  holds `:verification_failed` back deliberately — "a session may not report the outcome of
  a check it does not perform" — and its source filter stops at `merged`, so nothing a
  runner sends can write `{deployed, verified}` either. Until this module existed, ESCALATION
  WAS THE ONLY WAY OUT OF `deployed`. This is the writer of both edges.

  ## What it compares, and why not the workflow run

  The story's recorded `merge_sha` against the commits the target environment's recent
  DEPLOYMENTS name. Never a workflow run's `head_sha`: design §9 and KB `3670a0de` — a
  `workflow_run` deploy checks out the TRIGGERING run's commit while the API attributes the
  deploy run to whatever the branch head was when the run was created, so two merges four
  minutes apart produced a Deploy run attributed to the second that had shipped the first,
  with every surface reporting success. A deployment record's `sha` is written by the
  deploying job, which is the only party that knows what it checked out.

  **A ROLLBACK IS NOT DISTINGUISHED, and this is the honest statement of it.** A story whose
  carrying deployment succeeded is `:verified`, and it stays `:verified` if a later deploy
  rolls production back to an earlier commit. Every signal available here says it shipped,
  because it did — at the moment it was checked. What would distinguish the two is the
  ENVIRONMENT'S ACTIVE deployment rather than its recent ones, and GitHub exposes no
  endpoint for that: "active" has to be inferred as "the newest whose latest status is
  `success` and which is not `inactive`", which is the same shape as an ordinary deploy of
  another branch, so inferring it would trade a missed rollback for a false escalation on
  the commoner case. Closing it properly needs the artifact check below — asking the running
  application what it is running — and that needs an endpoint on the target app.

  An earlier version of this note claimed a rollback "waits out the long bound". That was
  wrong: the carrying deployment is still inside the window, so the sweep reaches a verdict
  rather than waiting.

  **Known bound, stated rather than discovered later:** this is only as good as what the
  deploy job wrote on the deployment. A job that creates its deployment with the attributed
  sha instead of the one it checked out reproduces the trap one layer down, and nothing
  here can see that. The stronger check is the artifact — query the deployed app for
  something only the new commit has — and it needs an endpoint on the target application
  that does not exist. What this module gives is the forge's own record instead of the
  forge's attribution, which is the improvement available without one.

  ## Three things it reads that a naive version does not, each paid for by a defect

  - **CONTAINMENT, not sha equality.** A merge that is an ANCESTOR of a deployed commit
    shipped. Merges queue, so a story merged at 10:00 and carried by the 10:04 deploy of a
    later merge is deployed, and equality would escalate it.
  - **A PAGE of deployments, not the newest one.** A verdict about one merge comes from the
    deployment that would have CARRIED it, which is not always the newest: A merges and
    deploy 1 carries it, B merges and deploy 2 fails, and reading only the newest escalated
    A — a story that had already shipped — on B's failure.
  - **The TIME the merge was recorded.** A deployment created before the merge cannot
    contain it. Between a runner reporting `deployed` and the deploy job creating its record
    (a queued workflow on a cold runner: routinely 30-120s) the newest deployment is the
    PREVIOUS one, and a verifier with no notion of time could not tell "my deploy has not
    started" from "something else shipped" — so the first sweep, which lands inside that
    window, took the human-only `verification_failed` edge on every healthy delivery.

  ## Every outcome

  **ANY carrying deployment that succeeded wins.** Not the first carrier and not the newest:
  in a single-branch pipeline every later deploy is of a descendant and therefore carries
  every earlier merge, so "the newest carrier decides" means a later story's failed deploy
  escalates an earlier story whose code is running. A newer carrying FAILURE over an older
  carrying SUCCESS means the ship still stands; failure is concluded only when NO carrying
  deployment ever succeeded.

  "Succeeded" is read from the deployment's status HISTORY, not its latest status, because
  GitHub writes `inactive` over an earlier deployment as soon as a newer one succeeds — so a
  deployment that shipped is routinely `inactive` by the time a sweep reads it.

  | what the forge says | decision | what happens to the story |
  |---|---|---|
  | ANY deployment carrying the merge ever succeeded | `:verified` | `{deployed, verified, :forward}` |
  | deployments carry it, none ever succeeded, all settled | `:failed` | escalated, naming the state and both shas |
  | deployments carry it, none succeeded, one is still running | `:unresolved` | nothing. The next sweep asks again |
  | NO deployment since the merge | `:unresolved` | nothing. The deploy job has not made its record |
  | deployments exist, none carries the merge | `:unresolved` | nothing, until the bound. A rollback or a concurrent branch, not a verdict |
  | the story has no recorded `merge_sha`, or no merge TIME | `:failed` | escalated. Fail closed: there is nothing to verify against |
  | a state this module does not know | `:failed` | escalated. Never approximated to success |
  | a TRANSIENT forge fault | `:unresolved` | nothing. The next sweep asks again |

  A failed deployment that does NOT carry the merge is passed over entirely — it is
  somebody else's deploy and says nothing about this story.

  ## A transient fault is not a verdict, and neither is a deploy still running

  `escalated` is human-only, so one 5s timeout, one rate-limit 403, or one queued build
  would park a story until Mark acts. Both come back `:unresolved`: nothing decided, nothing
  transitioned. The classification is `Loopctl.Delivery.MergePrecondition.transient?/1` —
  the SAME one the merge gate uses, not a second opinion about what GitHub's 403 means.

  The backstop is the same shape as the merge gate's, with one difference that matters:
  **TWO bounds, not one.** Consecutive unresolved sweeps are counted per MERGE and per KIND
  (`Loopctl.Delivery.Stages.note_post_deploy_unresolved/5`), and past
  `max_consecutive_unresolved/1` for that kind the verdict becomes a refusal that escalates
  naming the fault. A forge fault is a blip measured in minutes; a deploy that has not
  settled is measured in however long a queued build takes, and design §9 makes CI a
  capacity-1 resource. One number for both meant the slower condition inherited the faster
  one's ceiling and escalated every story on the normal path.

  The count is keyed to the merge rather than the head because that is what a sweep asks
  about, and every edge that clears `merge_sha` clears it
  (`Loopctl.Delivery.StageMachine.merge_keyed/0`) — so a merge that was retracted and
  re-made does not escalate on its predecessor's blips.

  ## Where it runs, and how it resumes

  Nowhere in particular, like the merge precondition: a function on whatever node serves
  the call, owning no process and caching nothing. `Loopctl.Workers.PostDeployVerificationWorker`
  is the caller, an Oban cron sweep, because by `deployed` THE SESSION HAS ENDED — the stage
  is in `StageMachine.session_ends_at/0` and its runner slot has already gone back — so
  there is no caller left to poll an endpoint. A restart loses nothing: every fact comes
  from Postgres or the forge, and the next sweep re-reads both.

  ## Retries and partitions

  `evaluate/2` writes nothing and may be repeated freely. `enforce/3` adds the transition,
  which is the stage machine's compare-and-set from `deployed`, so a second run of the same
  sweep finds the row already at `verified` or `escalated` and is refused `:stale_stage` —
  it cannot verify twice or escalate twice. The count is a fenced write like any other.

  A forge partition is `:unresolved` by construction: nothing can be established, so nothing
  is decided. A partition between two loopctl nodes is not a partition of the state — both
  write the one row and the compare-and-set lets exactly one commit.

  ## Slow connections

  Every forge call carries the bounded connect/receive timeouts
  `Loopctl.Delivery.GitHubPullRequestSource` sets, and `retry: false`. **No database
  transaction is open across any of them**: `gather/3` makes every call before `enforce/3`
  writes anything, exactly as the merge precondition does, so a slow forge never holds a
  pooled connection.

  ## What the reporter is told

  Every result carries a `Loopctl.Delivery.Resolution` — `:verified` is the only thing that
  produces a `:shipped` one, and `:unresolved` produces the same say-nothing resolution an
  escalation does. That is #805 item 1's other half: the merge is not the ship, so nothing
  before this module may tell a reporter a fix shipped.
  """

  require Logger

  alias Loopctl.Delivery.MergePrecondition
  alias Loopctl.Delivery.PostDeployVerification.Result
  alias Loopctl.Delivery.Resolution
  alias Loopctl.Delivery.StageMachine
  alias Loopctl.Delivery.Stages
  alias Loopctl.WorkBreakdown.Stories

  @default_environment "production"

  # TWO bounds, because two conditions reach `:unresolved` and they are not the same length
  # of problem. One number for both is how the normal path escalated: five sweeps is about
  # ten minutes, so every repository whose merge-to-deploy-settled time exceeded that
  # escalated EVERY story on the happy path.
  #
  # - `:forge_fault` — the forge could not be read. A blip clears in seconds; a fault that
  #   has not cleared in ten minutes is a token or an outage, and a human is the answer.
  #   The merge gate's number, for the same reason it has it.
  # - `:deploy_pending` — the deploy has not been created, has not settled, or has not
  #   carried this merge yet. Sized from what the delivery loop actually costs, not from the
  #   forge number: design §9 makes CI a capacity-1 resource on one self-hosted runner with
  #   six concurrent implementations feeding it, so a deploy queued behind other jobs for
  #   half an hour is ordinary rather than broken. An hour is the point at which a human
  #   should look.
  #
  # At the sweep's two-minute cadence: ~10 minutes and ~60 minutes.
  # And a THIRD, over both kinds together. The per-kind counts restart when the kind
  # changes, which an intermittently 5xx-ing forge alternating with a wedged deploy exploits
  # by construction: neither count ever reaches its bound, the story sits at `deployed` for
  # ever and nobody is told — the one outcome the whole counter exists to prevent. The total
  # is kept over the merge alone (`Loopctl.Delivery.Stages`' `totalled_by`) and is set above
  # the longest single-kind bound, so it only ever fires on a run that alternated.
  @max_consecutive_forge_faults 5
  @max_consecutive_deploy_pending 30
  @max_consecutive_total 40

  # Matches `Loopctl.Delivery.MergePrecondition`'s: the `story_stages_text_bounds` CHECK is
  # 4000 CODEPOINTS, and the margin is deliberate. A reason too long to store would roll the
  # transition back and leave the story at `deployed` with nothing recorded, which is the one
  # outcome a fail-closed gate cannot have.
  @reason_budget 3_900

  @type fact(value) :: {:ok, value} | {:error, term()}

  @typedoc "Which kind of waiting an `:unresolved` result is, and therefore which bound it has."
  @type unresolved_kind :: :forge_fault | :deploy_pending

  @typedoc """
  Each deployment carries the containment answer alongside its own facts: `contains` is
  `true` when the forge confirmed this deployment reaches the merge, `false` when it does
  not, and `:not_asked` when the walk stopped before needing to ask.
  """
  @type judged_deployment :: %{
          id: integer(),
          sha: String.t(),
          state: atom(),
          created_at: DateTime.t(),
          contains: boolean() | :not_asked
        }

  @type facts :: %{
          required(:repo) => fact(String.t()),
          required(:environment) => String.t(),
          required(:merge_sha) => String.t() | nil,
          required(:merged_at) => fact(DateTime.t()),
          required(:deployments) => fact([judged_deployment()]) | :not_attempted
        }

  @type error :: :not_found | :no_stage | :wrong_stage

  @doc "The transition a passing verification takes."
  @spec success_transition() :: StageMachine.transition()
  def success_transition, do: {:deployed, :verified, :forward}

  @doc "The transition a failing verification takes."
  @spec failure_transition() :: StageMachine.transition()
  def failure_transition, do: {:deployed, :escalated, :verification_failed}

  @doc """
  The consecutive-unresolved bound for one KIND of waiting. Past it the sweep escalates
  rather than answering "not yet" again, so neither a fault nor a stuck deploy can wait for
  ever with nobody told. See the note above `@max_consecutive_forge_faults` for why the two
  kinds do not share a number.
  """
  @spec max_consecutive_unresolved(unresolved_kind()) :: pos_integer()
  def max_consecutive_unresolved(:forge_fault), do: @max_consecutive_forge_faults
  def max_consecutive_unresolved(:deploy_pending), do: @max_consecutive_deploy_pending

  @doc """
  The bound over BOTH kinds together, which is what stops a story alternating between them
  from waiting for ever. See the note above `@max_consecutive_total`.
  """
  @spec max_consecutive_total() :: pos_integer()
  def max_consecutive_total, do: @max_consecutive_total

  @doc """
  The deployment environment whose newest deployment is compared against a story's merge.

  Fleet-wide, from `:delivery_deploy_environment` (`DELIVERY_DEPLOY_ENVIRONMENT`). One name
  for every repository is a simplification and is named as one: a tenant whose repositories
  deploy to differently-named environments needs this per intake source instead, and that
  is what would overturn it. Until then a wrong name is not a silent pass — the environment
  has no deployments, and the verifier escalates.
  """
  @spec environment() :: String.t()
  def environment,
    do: Application.get_env(:loopctl, :delivery_deploy_environment, @default_environment)

  @doc """
  The whole decision, as a pure function of the facts — no database, no forge, no
  application environment. See the moduledoc for the outcomes and `t:facts/0` for the shape.
  """
  @spec judge(facts()) :: Result.t()
  def judge(facts) do
    base = %Result{
      decision: :unresolved,
      reasons: [],
      resolution: Resolution.for_verdict(:escalated),
      repo: value(facts, :repo),
      merge_sha: Map.get(facts, :merge_sha),
      merged_at: value(facts, :merged_at)
    }

    # A transient fault decides FIRST and decides everything: nothing was established, so
    # nothing transitions. Only then the permanent faults, and only then the comparison.
    case {transient_reasons(facts), broken_reasons(facts)} do
      {[_ | _] = transient, other} ->
        unresolved(base, transient ++ other, :forge_fault, longest_retry_after(transient))

      {[], [_ | _] = broken} ->
        failed(base, broken)

      {[], []} ->
        decide(base, facts)
    end
  end

  @doc """
  Gathers the facts for a story at `deployed` and judges them. Writes nothing, and opens no
  transaction across a forge call.

  ## Errors

  `{:error, :not_found}` for a story that is not in the tenant, `{:error, :no_stage}` when
  it has no stage row, and `{:error, :wrong_stage}` when the row is not at `deployed` — the
  only stage this check is about. These are the caller asking at the wrong moment, not
  verdicts about the deploy.
  """
  @spec evaluate(Ecto.UUID.t(), Ecto.UUID.t()) :: {:ok, Result.t()} | {:error, error()}
  def evaluate(tenant_id, story_id) do
    with {:ok, story} <- fetch_story(tenant_id, story_id),
         {:ok, stage} <- fetch_stage(tenant_id, story_id) do
      {:ok, tenant_id |> gather(story, stage) |> judge()}
    end
  end

  @doc """
  `evaluate/2`, plus the one transition its decision implies.

  - `:verified` — `{deployed, verified, :forward}`, then the unresolved count is cleared
  - `:failed` — `{deployed, escalated, :verification_failed}`, with a reason naming every
    failure and both shas
  - `:unresolved` — the count is incremented and nothing transitions, until the count passes
    `max_consecutive_unresolved/0`, at which point the verdict becomes `:failed` and
    escalates through the ordinary path

  Returns the result either way. A transition that could not be written is LOGGED and
  reported on the result's reasons as `{:transition_failed, to, edge, reason}` — the
  decision still stands, and a caller must never read a failed escalation as a verification.

  ## Options

  - `:claim_epoch` (required) — the epoch the caller acts under, fencing every write here
    exactly as every other transition is fenced
  - `:actor_label`, `:actor_role`, `:actor_lineage` — attribution. `:actor_lineage` is
    REQUIRED, because escalating is a chained transition and `Stages.advance/4` refuses an
    absent lineage so "resolved, and empty" cannot be confused with "forgot to resolve". A
    cron sweep holds no key and states `[]`, which is an attested absence
  """
  @spec enforce(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, Result.t()} | {:error, error()}
  def enforce(tenant_id, story_id, opts) do
    with {:ok, result} <- evaluate(tenant_id, story_id) do
      {:ok, act(tenant_id, story_id, result, opts)}
    end
  end

  # -- the judgement (pure) --------------------------------------------------------------

  # A fact is judged only when it was ATTEMPTED. `:not_attempted` is the consequence of a
  # fact missing above it, never a second fault, so listing it would report the same problem
  # twice and — worse — a transient classification of it would suppress the permanent reason
  # that caused it.
  @judged_facts [
    {:repo, :repository_unresolved},
    {:merged_at, :merge_time_unknown},
    {:deployments, :deployments_unavailable}
  ]

  defp transient_reasons(facts) do
    for {key, kind} <- @judged_facts,
        reason = error_reason(facts, key),
        MergePrecondition.transient?(reason),
        do: {kind, reason}
  end

  defp broken_reasons(facts) do
    for {key, kind} <- @judged_facts,
        reason = error_reason(facts, key),
        not MergePrecondition.transient?(reason),
        do: {kind, reason}
  end

  defp error_reason(facts, key) do
    case Map.get(facts, key) do
      {:ok, _value} -> nil
      :not_attempted -> nil
      {:error, reason} -> reason
      other -> {:missing_fact, shape(other)}
    end
  end

  # The states that say a deployment is FINISHED and did not ship.
  #
  # `:inactive` is deliberately IN this list and deliberately not enough on its own: it is
  # reached both by a genuine deactivation and by GitHub auto-inactivating an earlier
  # deployment the moment a newer one succeeds. Which one it is, is answered by
  # `succeeded?`, which the `verified` branch above reads FIRST — so an `:inactive`
  # deployment that once succeeded has already won by the time this list is consulted, and
  # what reaches here is one that was deactivated having never shipped.
  @settled_failure [:failure, :error, :inactive]

  # Everything the forge could say has been established by here. What is left is the
  # question, in the order a reader would ask it: do we know what had to ship, and does any
  # deployment that could have carried it say it did.
  defp decide(result, facts) do
    case Map.get(facts, :merge_sha) do
      nil -> failed(result, [:merge_sha_not_recorded])
      merge_sha -> decide_deployments(result, facts, merge_sha, value(facts, :deployments))
    end
  end

  # NO deployment created since the merge. The deploy job has not made its record yet, which
  # is the ORDINARY state of a story that reached `deployed` seconds ago: a queued workflow
  # on a cold runner routinely takes 30-120s to get there. This is the case that used to
  # escalate the happy path, because the newest deployment was then the PREVIOUS one, which
  # by construction cannot contain this merge.
  defp decide_deployments(result, facts, merge_sha, []) do
    reason = {:deploy_not_started, merge_sha, Map.get(facts, :environment)}
    unresolved(result, [reason], :deploy_pending, nil)
  end

  # **ANY carrying deployment that SUCCEEDED wins.** Not the first, and emphatically not the
  # newest: in a single-branch pipeline every later deploy is of a descendant and therefore
  # carries every earlier merge, so "the newest carrier decides" means a later story's
  # failed deploy escalates an earlier story whose code is running. That is the regression
  # reading a page was supposed to fix, reintroduced one layer along by halting the walk at
  # the first carrier.
  #
  # A newer carrying FAILURE over an older carrying SUCCESS means the ship still stands.
  # Failure is concluded only when NO carrying deployment succeeded.
  defp decide_deployments(result, _facts, merge_sha, deployments) do
    carrying = Enum.filter(deployments, & &1.contains)

    case Enum.find(carrying, & &1.succeeded?) do
      %{} = shipped -> verified(result, shipped)
      nil -> not_shipped(result, merge_sha, carrying, deployments)
    end
  end

  defp verified(result, deployment) do
    %{
      result
      | decision: :verified,
        reasons: [],
        resolution: Resolution.for_verdict(:shipped),
        deployed_sha: deployment.sha,
        deployment_id: deployment.id,
        deployment_state: deployment.state
    }
  end

  # Nothing that carries the merge has ever succeeded. Which of the three that is depends on
  # what the carriers are doing, and on whether there are any.
  defp not_shipped(result, merge_sha, [], deployments),
    do: nothing_carries_it(result, merge_sha, deployments)

  defp not_shipped(result, merge_sha, carrying, _deployments) do
    newest = List.first(carrying)

    result = %{
      result
      | deployed_sha: newest.sha,
        deployment_id: newest.id,
        deployment_state: newest.state
    }

    cond do
      Enum.any?(carrying, &(&1.state == :pending)) ->
        # Our deploy is running. Not a failure, and the common case seconds after a merge.
        unresolved(result, [{:deploy_in_flight, newest.sha, merge_sha}], :deploy_pending, nil)

      Enum.all?(carrying, &(&1.state in @settled_failure)) ->
        failed(result, [{:deploy_not_successful, newest.state, newest.sha, merge_sha}])

      true ->
        # A state this module does not know, on a deployment that carries the merge. NEVER
        # approximated to success: the dispatch used to fall through to a verification.
        failed(result, [{:unrecognised_deployment_state, newest.state}])
    end
  end

  # Deployments exist since the merge, none carries it. Either one is still running and
  # will, or something shipped past this merge without it. Both are WAITING, bounded by the
  # in-flight count, which escalates naming both shas. Concluding failure here read a
  # concurrent deploy as a broken one.
  defp nothing_carries_it(result, merge_sha, deployments) do
    newest = List.first(deployments)

    result = %{
      result
      | deployed_sha: newest && newest.sha,
        deployment_id: newest && newest.id,
        deployment_state: newest && newest.state
    }

    reasons =
      if Enum.any?(deployments, &(&1.state == :pending)),
        do: [{:deploy_in_flight, newest && newest.sha, merge_sha}],
        else: [{:merge_not_deployed, merge_sha, newest && newest.sha}]

    unresolved(result, reasons, :deploy_pending, nil)
  end

  # `retry_after` is a fact about the FORGE, not about the decision, so a conversion to
  # `:failed` KEEPS it. Nulling it disarmed the sweep's rate-limit halt on exactly the pass
  # that matters: the run that crosses the bound is the one that just heard "out of quota",
  # and the batch went on calling.
  defp failed(result, reasons) do
    %{
      result
      | decision: :failed,
        reasons: Enum.uniq(reasons),
        resolution: Resolution.for_verdict(:escalated)
    }
  end

  defp unresolved(result, reasons, kind, retry_after) do
    %{
      result
      | decision: :unresolved,
        unresolved_kind: kind,
        reasons: Enum.uniq(reasons),
        resolution: Resolution.for_verdict(:escalated),
        retry_after: retry_after
    }
  end

  # `Enum.max` cannot do this directly: in Erlang term order every atom sorts above every
  # number, so a single `nil` would win over a real delay.
  defp longest_retry_after(reasons) do
    reasons
    |> Enum.map(fn {_kind, reason} -> MergePrecondition.retry_after(reason) end)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      seconds -> Enum.max(seconds)
    end
  end

  defp value(facts, key) do
    case Map.get(facts, key) do
      {:ok, value} -> value
      _other -> nil
    end
  end

  # -- gathering the facts ---------------------------------------------------------------

  defp gather(tenant_id, story, stage) do
    repo = MergePrecondition.repo_for_story(story)
    env = environment()
    merged_at = merged_at(tenant_id, stage)

    %{
      repo: repo,
      environment: env,
      # From the STAGE ROW, never a caller: this is the merge the loop performed, written
      # inside the transition into `merged` and named in that transition's chain entry.
      merge_sha: stage.merge_sha,
      merged_at: merged_at,
      deployments: deployments(repo, env, merged_at, stage.merge_sha)
    }
  end

  # WHEN the loop recorded the merge, read from the stage event the transition into `merged`
  # wrote. That table is append-only and nothing prunes it, so the event is present for
  # every story that reached `deployed` — it is the transition that got it there.
  #
  # Its ABSENCE therefore means the story's own history does not say when it merged, which
  # is a custody-integrity gap like `merge_sha_not_recorded` and fails CLOSED. Defaulting to
  # "the beginning of time" would put every deployment back in the candidate set and restore
  # the failure this whole fact exists to remove.
  # How far BEFORE the recorded merge a deployment may have been created and still be a
  # candidate. Two clocks and two writers: `merged_at` is loopctl's commit time and
  # `created_at` is GitHub's, and a deploy job that creates its record before loopctl commits
  # the `merged` transition — or a few seconds of clock skew — would put the ONLY deployment
  # that can carry the merge permanently outside the window, on every sweep for ever, because
  # a record never gets newer. The cost of the tolerance is nil: an older deployment that
  # slips in simply answers `contains?` false.
  @clock_tolerance_seconds 120

  defp merged_at(tenant_id, stage) do
    tenant_id
    |> Stages.list_events(stage.story_id)
    |> Enum.filter(&(&1.event == "transitioned" and &1.to_stage == "merged"))
    |> List.last()
    |> case do
      %{inserted_at: at} -> {:ok, DateTime.add(at, -@clock_tolerance_seconds, :second)}
      nil -> {:error, :no_merge_event}
    end
  end

  @doc """
  The clock tolerance subtracted from the recorded merge time before asking the forge. See
  the note above `@clock_tolerance_seconds`.
  """
  @spec clock_tolerance_seconds() :: pos_integer()
  def clock_tolerance_seconds, do: @clock_tolerance_seconds

  # The deployments that could carry this merge, each annotated with whether it does.
  #
  # The walk is newest-first and SHORT-CIRCUITS on the first deployment the forge confirms
  # reaches the merge: that one settles the verdict, whatever its state, so nothing older
  # needs asking about. On the common path this is one containment call, and on the very
  # common early path the list is empty and there are none.
  defp deployments({:ok, repo}, environment, {:ok, merged_at}, merge_sha)
       when is_binary(merge_sha) do
    case source().deployments_since(repo, environment, merged_at) do
      {:ok, deployments} -> annotate(repo, merge_sha, deployments)
      {:error, reason} -> {:error, reason}
    end
  end

  defp deployments(_repo, _environment, _merged_at, _merge_sha), do: :not_attempted

  # Containment for every candidate, because the rule is "does ANY carrying deployment say
  # it succeeded" and that cannot be answered from one of them. The walk halts early on the
  # one answer that settles it — a carrier that SUCCEEDED — and the rest are then marked
  # `false` without being asked, since nothing they could say changes a verdict already
  # reached. Halting on the first CARRIER (rather than the first carrying success) is what
  # reintroduced the newest-deployment bug: in a single-branch pipeline every later deploy
  # carries every earlier merge, so the first carrier is just the newest deployment again.
  #
  # Bounded by the adapter's own survivor cap, so this is a handful of calls at worst and
  # one in the ordinary case.
  defp annotate(repo, merge_sha, deployments) do
    deployments
    |> Enum.reduce_while({:ok, [], false}, fn deployment, {:ok, acc, _done} ->
      case contains(repo, merge_sha, deployment) do
        {:ok, contains} ->
          annotated = Map.put(deployment, :contains, contains)
          settled = contains and deployment.succeeded?
          {if(settled, do: :halt, else: :cont), {:ok, [annotated | acc], settled}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, annotated, _settled} -> {:ok, unasked(Enum.reverse(annotated), deployments)}
      error -> error
    end
  end

  # The tail the walk never reached, marked `contains: false` so the judge sees one shape.
  # Sound because the walk only stops early on a verdict nothing here could change.
  defp unasked(annotated, deployments) do
    annotated ++
      (deployments
       |> Enum.drop(length(annotated))
       |> Enum.map(&Map.put(&1, :contains, false)))
  end

  # NOT asked when the shas are equal: a commit trivially contains itself, and the round
  # trip could only add a way to fail.
  defp contains(repo, merge_sha, %{sha: deployed}) do
    if merge_sha == deployed, do: {:ok, true}, else: source().contains?(repo, merge_sha, deployed)
  end

  defp fetch_story(tenant_id, story_id) do
    case Stories.get_story(tenant_id, story_id) do
      {:ok, story} -> {:ok, story}
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  defp fetch_stage(tenant_id, story_id) do
    case Stages.get(tenant_id, story_id) do
      nil -> {:error, :no_stage}
      %{stage: :deployed} = stage -> {:ok, stage}
      %{stage: _other} -> {:error, :wrong_stage}
    end
  end

  defp source do
    Application.get_env(
      :loopctl,
      :delivery_pull_request_source,
      Loopctl.Delivery.GitHubPullRequestSource
    )
  end

  # -- the writes ------------------------------------------------------------------------

  # The clear runs ONLY on a transition that landed. A `{:error, result}` here means the row
  # did not move — a lost race with a human, a stale epoch — so the story is still at
  # `deployed` and its unresolved count is still the live record of why; clearing it would
  # reset the backstop on the strength of a write that failed.
  defp act(tenant_id, story_id, %Result{decision: :verified} = result, opts) do
    case transition(tenant_id, story_id, result, success_transition(), opts) do
      {:ok, verified} -> clear_unresolved(tenant_id, story_id, verified, opts)
      {:error, unchanged} -> unchanged
    end
  end

  defp act(tenant_id, story_id, %Result{decision: :failed} = result, opts) do
    {_outcome, result} = transition(tenant_id, story_id, result, failure_transition(), opts)
    result
  end

  # Past the bound it stops being "not yet" and becomes a refusal, which escalates through
  # the ordinary path. The recursion terminates: the second call carries `:failed`.
  defp act(tenant_id, story_id, %Result{decision: :unresolved} = result, opts) do
    case note_unresolved(tenant_id, story_id, result, opts) do
      %Result{decision: :unresolved} = waiting -> waiting
      %Result{} = converted -> act(tenant_id, story_id, converted, opts)
    end
  end

  # Counting is itself a fenced write and can fail. A count that does not land leaves the
  # result `:unresolved` — the backstop is a safety net, not a second way to escalate — and
  # the failure is logged and reported.
  defp note_unresolved(tenant_id, story_id, %Result{unresolved_kind: kind} = result, opts) do
    write_opts = Keyword.take(opts, [:claim_epoch, :actor_label])
    bound = max_consecutive_unresolved(kind)

    tenant_id
    |> Stages.note_post_deploy_unresolved(story_id, result.merge_sha, kind, write_opts)
    |> case do
      {:ok, %{count: count}} when count > bound ->
        failed(result, result.reasons ++ [{:unresolved_limit_exceeded, kind, count, bound}])

      # The alternating case. Neither per-kind count reached its bound, and it never would.
      {:ok, %{total: total}} when total > @max_consecutive_total ->
        failed(
          result,
          result.reasons ++ [{:unresolved_total_exceeded, total, @max_consecutive_total}]
        )

      {:ok, _counts} ->
        result

      {:error, reason} ->
        Logger.warning(
          "post_deploy unresolved not counted story_id=#{story_id} tenant_id=#{tenant_id} " <>
            "reason=#{inspect(reason)}"
        )

        %{result | reasons: result.reasons ++ [{:unresolved_not_counted, reason}]}
    end
  end

  # A verification that PRODUCED a verdict ends whatever run of unresolved sweeps preceded
  # it. A failure to clear is tidying that did not land, not a verdict withheld: the story
  # is already at `verified`, and the count it leaves behind is cleared by the merge-keyed
  # clear on any path that re-opens the work.
  defp clear_unresolved(tenant_id, story_id, %Result{} = result, opts) do
    write_opts = Keyword.take(opts, [:claim_epoch, :actor_label])

    case Stages.clear_post_deploy_unresolved(tenant_id, story_id, write_opts) do
      {:ok, _outcome} ->
        result

      {:error, reason} ->
        Logger.warning(
          "post_deploy unresolved count not cleared story_id=#{story_id} " <>
            "tenant_id=#{tenant_id} reason=#{inspect(reason)}"
        )

        %{result | reasons: result.reasons ++ [{:unresolved_not_cleared, reason}]}
    end
  end

  defp transition(tenant_id, story_id, %Result{} = result, {_from, to, edge} = target, opts) do
    advance_opts =
      opts
      |> Keyword.take([:claim_epoch, :actor_label, :actor_role, :actor_lineage])
      |> Keyword.put(:reason, reason_text(result))

    case Stages.advance(tenant_id, story_id, target, advance_opts) do
      {:ok, _row} ->
        {:ok, result}

      {:error, reason} ->
        Logger.warning(
          "post_deploy #{to}/#{edge} not written story_id=#{story_id} tenant_id=#{tenant_id} " <>
            "reason=#{inspect(reason)} result_reasons=#{inspect(result.reasons)}"
        )

        {:error, %{result | reasons: result.reasons ++ [{:transition_failed, to, edge, reason}]}}
    end
  end

  # BOTH shas open the reason, always, even when one of them is nil — "the wrong thing is
  # deployed" is unactionable without saying which two commits disagree, and an operator
  # reading the escalation must not have to go and look them up. `{deployed, verified}` is
  # not a reason-required transition, but the note is recorded on its event all the same.
  defp reason_text(%Result{merge_sha: merge_sha, deployed_sha: deployed, reasons: reasons}) do
    bound_codepoints(
      "post_deploy (merge_sha: #{inspect(merge_sha)}, deployed_sha: #{inspect(deployed)}): " <>
        Enum.map_join(reasons, "; ", &inspect/1)
    )
  end

  # CODEPOINTS, matching Postgres `char_length` and `Stages`' own bound. A codepoint prefix
  # can split a grapheme cluster; that is cosmetic and the string stays valid UTF-8, which
  # is the trade against an escalation that will not write at all.
  defp bound_codepoints(text) do
    chars = String.to_charlist(text)

    if length(chars) > @reason_budget,
      do: chars |> Enum.take(@reason_budget - 1) |> List.to_string() |> Kernel.<>("…"),
      else: text
  end

  # Only the SHAPE of an unexpected value is echoed into a stored reason.
  defp shape(%module{}), do: module
  defp shape(value) when is_map(value), do: {:map, value |> Map.keys() |> Enum.sort()}
  defp shape(value) when is_list(value), do: {:list, length(value)}
  defp shape(value) when is_atom(value), do: value
  defp shape(_value), do: :unreadable
end
