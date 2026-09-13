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

  The story's recorded `merge_sha` against the commit the target environment's newest
  DEPLOYMENT names. Never a workflow run's `head_sha`: design §9 and KB `3670a0de` — a
  `workflow_run` deploy checks out the TRIGGERING run's commit while the API attributes the
  deploy run to whatever the branch head was when the run was created, so two merges four
  minutes apart produced a Deploy run attributed to the second that had shipped the first,
  with every surface reporting success. A deployment record's `sha` is written by the
  deploying job, which is the only party that knows what it checked out.

  **Known bound, stated rather than discovered later:** this is only as good as what the
  deploy job wrote on the deployment. A job that creates its deployment with the attributed
  sha instead of the one it checked out reproduces the trap one layer down, and nothing
  here can see that. The stronger check is the artifact — query the deployed app for
  something only the new commit has — and it needs an endpoint on the target application
  that does not exist. What this module gives is the forge's own record instead of the
  forge's attribution, which is the improvement available without one.

  ## Containment, not equality

  A merge that is an ANCESTOR of the deployed commit shipped. Merges queue: a story merged
  at 10:00 and deployed inside the 10:04 deploy of a later merge is deployed, and equality
  would escalate it. `PullRequestSource.contains?/3` is the question actually asked, and
  identical shas skip the call rather than making it.

  ## Every outcome

  | what the forge says | decision | what happens to the story |
  |---|---|---|
  | the merge is in the deployed commit, deployment succeeded | `:verified` | `{deployed, verified, :forward}` |
  | it is not | `:failed` | `{deployed, escalated, :verification_failed}`, naming both shas |
  | the deployment failed, errored, or was deactivated (rolled back) | `:failed` | escalated, naming the state |
  | the environment has NO deployment | `:failed` | escalated. We cannot tell what is running, and that is a human's question |
  | the story has no recorded `merge_sha` | `:failed` | escalated. Fail closed: there is nothing to verify against |
  | a TRANSIENT forge fault | `:unresolved` | nothing. The next sweep asks again |
  | the deployment has not settled | `:unresolved` | nothing. A deploy in flight is not a failed one |

  ## A transient fault is not a verdict, and neither is a deploy still running

  `escalated` is human-only, so one 5s timeout, one rate-limit 403, or one deploy that
  takes six minutes would park a story until Mark acts. Both come back `:unresolved`:
  nothing decided, nothing transitioned. The classification is
  `Loopctl.Delivery.MergePrecondition.transient?/1` — the SAME one the merge gate uses, not
  a second opinion about what GitHub's 403 means — and the backstop is the same shape too:
  consecutive unresolved sweeps at one MERGE are counted
  (`Loopctl.Delivery.Stages.note_post_deploy_unresolved/4`), and past
  `max_consecutive_unresolved/0` the verdict becomes a refusal that escalates naming the
  fault. No condition retries for ever with nobody told.

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

  `evaluate/3` writes nothing and may be repeated freely. `enforce/3` adds the transition,
  which is the stage machine's compare-and-set from `deployed`, so a second run of the same
  sweep finds the row already at `verified` or `escalated` and is refused `:stale_stage` —
  it cannot verify twice or escalate twice. The count is a fenced write like any other.

  A forge partition is `:unresolved` by construction: nothing can be established, so nothing
  is decided. A partition between two loopctl nodes is not a partition of the state — both
  write the one row and the compare-and-set lets exactly one commit.

  ## Slow connections

  Every forge call carries the bounded connect/receive timeouts
  `Loopctl.Delivery.GitHubPullRequestSource` sets, and `retry: false`. **No database
  transaction is open across any of them**: `gather/2` makes every call before `enforce/3`
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

  # The same bound, and the same reasoning, as the merge gate's: the cost of escalating a
  # story that would have recovered is one human glance, and the cost of not escalating is a
  # story nobody hears about again. At the sweep's cadence this is roughly ten minutes of a
  # deploy that will not settle or a forge that will not answer.
  @max_consecutive_unresolved 5

  # Matches `Loopctl.Delivery.MergePrecondition`'s: the `story_stages_text_bounds` CHECK is
  # 4000 CODEPOINTS, and the margin is deliberate. A reason too long to store would roll the
  # transition back and leave the story at `deployed` with nothing recorded, which is the one
  # outcome a fail-closed gate cannot have.
  @reason_budget 3_900

  @type fact(value) :: {:ok, value} | {:error, term()}

  @type facts :: %{
          required(:repo) => fact(String.t()),
          required(:environment) => String.t(),
          required(:merge_sha) => String.t() | nil,
          required(:deployment) => fact(map() | nil),
          required(:contains) => fact(boolean()) | :not_attempted
        }

  @type error :: :not_found | :no_stage | :wrong_stage

  @doc "The transition a passing verification takes."
  @spec success_transition() :: StageMachine.transition()
  def success_transition, do: {:deployed, :verified, :forward}

  @doc "The transition a failing verification takes."
  @spec failure_transition() :: StageMachine.transition()
  def failure_transition, do: {:deployed, :escalated, :verification_failed}

  @doc """
  The consecutive-unresolved bound. Past it the sweep escalates rather than answering "not
  yet" again, so no fault and no stuck deploy can wait for ever with nobody told.
  """
  @spec max_consecutive_unresolved() :: pos_integer()
  def max_consecutive_unresolved, do: @max_consecutive_unresolved

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
      deployed_sha: deployed(facts, :sha),
      deployment_id: deployed(facts, :id),
      deployment_state: deployed(facts, :state)
    }

    # A transient fault decides FIRST and decides everything: nothing was established, so
    # nothing transitions. Only then the permanent faults, and only then the comparison.
    case {transient_reasons(facts), broken_reasons(facts)} do
      {[_ | _] = transient, other} ->
        unresolved(base, transient ++ other, longest_retry_after(transient))

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
      {:ok, story |> gather(stage) |> judge()}
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

  # `:contains` is judged only when it was ATTEMPTED. `:not_attempted` is the consequence of
  # a fact missing above it, never a second fault, so listing it would report the same
  # problem twice and — worse — a transient classification of it would suppress the
  # permanent reason that caused it.
  @judged_facts [
    {:repo, :repository_unresolved},
    {:deployment, :deployment_unavailable},
    {:contains, :containment_unavailable}
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

  # Everything the forge could say has been established by here. What is left is the
  # question, in the order a reader would ask it: do we know what had to ship, did the
  # deploy happen, did it succeed, and is our commit in it.
  defp decide(result, facts) do
    case {Map.get(facts, :merge_sha), value(facts, :deployment)} do
      {nil, _deployment} ->
        failed(result, [:merge_sha_not_recorded])

      {_merge_sha, nil} ->
        failed(result, [{:no_deployment, Map.get(facts, :environment)}])

      {merge_sha, deployment} ->
        decide_deployment(result, facts, merge_sha, deployment)
    end
  end

  # A deploy that has not settled is not a failed one. It is the ordinary case for a story
  # that reached `deployed` seconds ago, and escalating on it would make the common path the
  # escalating one.
  defp decide_deployment(result, _facts, merge_sha, %{state: :pending} = deployment),
    do: unresolved(result, [{:deploy_in_flight, deployment.sha, merge_sha}], nil)

  defp decide_deployment(result, _facts, merge_sha, %{state: state} = deployment)
       when state in [:failure, :error, :inactive] do
    # `:inactive` is the newest deployment of the environment having been DEACTIVATED, which
    # is a rollback: nothing newer superseded it, because this is the newest one.
    failed(result, [{:deploy_not_successful, state, deployment.sha, merge_sha}])
  end

  defp decide_deployment(result, facts, merge_sha, deployment) do
    case value(facts, :contains) do
      true ->
        %{
          result
          | decision: :verified,
            reasons: [],
            resolution: Resolution.for_verdict(:shipped)
        }

      _not_contained ->
        failed(result, [{:merge_not_deployed, merge_sha, deployment.sha}])
    end
  end

  defp failed(result, reasons) do
    %{
      result
      | decision: :failed,
        reasons: Enum.uniq(reasons),
        resolution: Resolution.for_verdict(:escalated),
        retry_after: nil
    }
  end

  defp unresolved(result, reasons, retry_after) do
    %{
      result
      | decision: :unresolved,
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

  defp deployed(facts, key) do
    case value(facts, :deployment) do
      %{} = deployment -> Map.get(deployment, key)
      _absent -> nil
    end
  end

  # -- gathering the facts ---------------------------------------------------------------

  defp gather(story, stage) do
    repo = MergePrecondition.repo_for_story(story)
    env = environment()
    deployment = latest_deployment(repo, env)

    %{
      repo: repo,
      environment: env,
      # From the STAGE ROW, never a caller: this is the merge the loop performed, written
      # inside the transition into `merged` and named in that transition's chain entry.
      merge_sha: stage.merge_sha,
      deployment: deployment,
      contains: contains(repo, stage.merge_sha, deployment)
    }
  end

  defp latest_deployment({:ok, repo}, environment),
    do: source().latest_deployment(repo, environment)

  defp latest_deployment(_repo, _environment), do: {:error, :not_attempted}

  # Only asked when there is something to ask about — a SUCCESSFUL deployment and a merge to
  # look for — and NOT asked when the shas are equal: a commit trivially contains itself, and
  # the round trip could only add a way to fail.
  defp contains({:ok, repo}, merge_sha, {:ok, %{sha: deployed, state: :success}})
       when is_binary(merge_sha) do
    if merge_sha == deployed, do: {:ok, true}, else: source().contains?(repo, merge_sha, deployed)
  end

  defp contains(_repo, _merge_sha, _deployment), do: :not_attempted

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
  defp note_unresolved(tenant_id, story_id, %Result{} = result, opts) do
    write_opts = Keyword.take(opts, [:claim_epoch, :actor_label])

    case Stages.note_post_deploy_unresolved(tenant_id, story_id, result.merge_sha, write_opts) do
      {:ok, count} when count > @max_consecutive_unresolved ->
        failed(result, result.reasons ++ [{:unresolved_limit_exceeded, count}])

      {:ok, _count} ->
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
