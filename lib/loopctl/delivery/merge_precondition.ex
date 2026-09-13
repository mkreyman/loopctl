defmodule Loopctl.Delivery.MergePrecondition do
  @moduledoc """
  The SECOND run of both delivery gates, over the real pull request (issue #803, design §5
  "Both gates run twice" and §9).

  The triage run evaluates the trio's PREDICTED touch list and decides only whether to
  dispatch. Nothing binds an implementing session to that prediction, so a gate that ran
  only there certifies a guess. This module runs the same two gates over the diff that
  actually exists, and it is the run that gates a merge.

  ## Three functions, split by what they touch

  - `judge/1` is PURE — no database, no forge, no application environment. Every fact it
    decides on is an argument, exactly as `Loopctl.DeliveryGates` is written, and every
    fact may arrive as `{:error, reason}` for something that could not be established. That
    is what makes the fail-closed paths — a forge that timed out, a diff that did not
    parse, a project with no repository — decidable without any I/O at all.
  - `evaluate/3` gathers those facts and calls `judge/1`. Writes nothing.
  - `enforce/3` is `evaluate/3` plus the one write a refusal implies.

  ## What has to be true to merge

  All four, and every one of them can only ADD a refusal:

  1. **Gate A** (`Loopctl.DeliveryGates.gate_a/1`) over the triage trio's outputs —
     `:proceed`, on a unanimous `story` verdict. A `reject` verdict is not something to
     merge, and anything malformed escalates by construction.
  2. **Gate B** (`Loopctl.DeliveryGates.gate_b/3`) at `:merge` — `:clear`. A
     `:prove_effect` outcome REFUSES today whatever proof the call carried: the proof is a
     caller assertion by the same principal that drives the merge, so accepting it would
     wave through exactly the changes the gate exists for. It is judged
     (`Loopctl.DeliveryGates.judge_proof/4`) and recorded either way. The design's Gate B
     harness — regenerating fixture output server-side — is what turns a pass into an allow.
  3. **The design's hard bound** — 12 files, 1,000 changed lines — applied on TOP of the
     configured limits, so a configuration that raises `max_files` cannot raise this. It is
     applied to the FORGE's own diffstat, never to the length of a file list that may have
     been truncated.
  4. **Custody** (design §9) — `verified_status: :verified`, set through a verifier
     dispatch whose lineage is separate from the implementer's. That comparison is
     `Loopctl.Progress.merge_custody_status/1`, which is the L4 gate `verify` already runs;
     there is no second lineage comparison here.
  5. **The head has not moved** — the pull request's head must be the `head_sha` the stage
     row recorded, which is the head CI ran on and the story was verified at. A push after
     either is ordinary work rather than an escalation, so it goes back to `implementing`
     on `:base_moved`; it does not merge, because no CI run and no verifier saw it.

  ## Gate A's inputs are caller-asserted, and every verdict says so

  The triage trio's outputs arrive in the request because triage does not persist them yet,
  so a fabricated trio clears Gate A. `gate_a_inputs: :caller_asserted` is on every verdict
  and opens every escalation reason. Triage persisting its verdict against the story is
  what closes it; nothing else here can, and pretending otherwise would be worse than
  saying it.

  ## Fail closed, everywhere

  A missing, empty, misparsed or checksum-mismatched trigger document, an unknown
  repository, a project with no intake source to resolve a repository from, a forge that
  is unreachable, rate-limited or truncating, a diff that does not parse, a stale trigger,
  a story with no recorded custody — every one is a `:refuse` naming what failed. There is
  no input, and no failure, that produces an `:allow` on incomplete knowledge. A refusal
  also carries the WHOLE list rather than the first item: Gate A and the custody check are
  evaluated even when the forge failed, because a caller fixing one reason should not have
  to run the gate again to discover the next.

  Gate B is run TWICE, over `repo_files` at the pull request's head AND at its merge base,
  and the two results are OR-ed. A configured pattern that matches at one ref and not the
  other is drift — the rename that silently unguards a trigger is precisely the case where
  the two disagree — so a stale trigger at EITHER ref escalates.

  ## Where it runs, and how a caller reaches it after a restart

  Nowhere in particular. It is a function on whatever loopctl node serves the call; it owns
  no process and caches nothing, so there is no owner to find again. Every fact it reads
  comes from Postgres (`Loopctl.WorkBreakdown.Stories`, `Loopctl.Delivery.Stages`,
  `Loopctl.Intake`, `Loopctl.Progress`) or from the forge, and both survive a restart. A
  caller that crashed mid-evaluation asks again.

  ## Partitions and slow connections

  The forge is the partitionable dependency, and it is reached through
  `Loopctl.Delivery.PullRequestSource` — a behaviour, config-resolved, with bounded
  timeouts in its production implementation. Unreachable means REFUSE: the design's rule is
  that a clean result merges with no human and anything else routes to Gate A, and "we
  could not tell" is emphatically anything else. Every forge call is made BEFORE any
  database transaction opens, so a slow forge never holds a pooled connection.

  ## Retries

  `evaluate/3` writes nothing, so it may be repeated freely: the same pull request at the
  same head gives the same answer, and a re-run after a new commit judges the NEW diff
  because every input is re-read. `enforce/3` adds one write — the `:merge_gate`
  escalation — and that write is the stage machine's compare-and-set, so a repeat finds the
  row already `escalated` and never escalates twice.

  A pull request the forge reports as ALREADY MERGED asks a different question — not
  whether to merge, but whether the gate ever AUTHORISED this merge. The only thing that
  can answer it is a RECORDED allow, so `enforce/3` writes `merge_gate_allowed_sha` on the
  stage row when it allows, keyed to the head it judged, and the already-merged branch
  compares it with the merged head:

  - the recorded allow names this head — `:already_merged`, adopt `merge_sha`. A caller that
    crashed between merging and recording the merge is told to finish, not escalated
  - no recorded allow, or one for a DIFFERENT head — `:refuse` with `{:ungated_merge, sha,
    why}`. The sha is still on the verdict and named in the escalation reason so the fact
    is not lost, but the last gate before an outward effect never reports clean for an
    effect it did not license
  - merged with no sha at all — `:refuse`. Reporting `already_merged` there would strand the
    caller: `advance/4` refuses a `merged` transition that names nothing

  The allow is cleared with `head_sha` by every edge that clears it
  (`Loopctl.Delivery.StageMachine.clears/3`), so a later, unjudged head can never inherit it.

  ## A transient forge fault is not a verdict

  Escalating is expensive: `escalated` is human-only, so one 5s timeout or one rate-limit
  403 would park a story until Mark acts. Those come back `:unevaluated` — nothing decided,
  nothing transitioned, the caller retries. `transient?/1` is the whole classification, and
  it is deliberately narrow: a 404, a 401, a body that does not parse and a truncated list
  are configuration or a contract change, and a human IS the right answer to each.

  ## The one write, and no second write path

  Every write goes through `Loopctl.Delivery.Stages`, the only writer of `story_stages`:

  - `:refuse` — `{:ci, :escalated, :merge_gate}`
  - `:head_moved` — `{:ci, :implementing, :base_moved}`, which also CLEARS the head and the
    recorded allow
  - `:allow` — `record_effect(:merge_gate_allowed_sha, head)`. A write that does not land
    turns the allow into a refusal, because an allow nobody recorded is an allow nobody can
    later account for
  - `:already_merged` and `:unevaluated` — nothing

  The merge itself is still the CALLER's: it merges and then advances `{:ci, :merged}`
  carrying the sha the forge returned, because the merge commit does not exist until the
  merge happens.
  """

  require Logger

  alias Loopctl.Delivery.MergePrecondition.Verdict
  alias Loopctl.Delivery.StageMachine
  alias Loopctl.Delivery.Stages
  alias Loopctl.DeliveryGates
  alias Loopctl.DeliveryGates.DiffNames
  alias Loopctl.DeliveryGates.GateA
  alias Loopctl.DeliveryGates.GateB
  alias Loopctl.Intake
  alias Loopctl.Progress
  alias Loopctl.WorkBreakdown.Stories

  # Design §5: "the 12-file / 1,000-line bound". A CEILING over the configured limits, not
  # a default for them — configuration may tighten it and may not loosen it. Without this,
  # a trigger document with `max_files: 500` would merge a 500-file change unread, and the
  # document is exactly the thing an agent-driven loop must not be able to talk around.
  @hard_max_files 12
  @hard_max_changed_lines 1_000

  # The `story_stages_text_bounds` CHECK on `escalation_reason` is
  # `char_length(...) BETWEEN 1 AND 4000`, and Postgres `char_length` counts CODEPOINTS —
  # as does `Loopctl.Delivery.Stages`' own `bounded_text/2`. So the reason is bounded in
  # codepoints, NOT graphemes: an NFD path or an emoji is several codepoints per grapheme,
  # and a grapheme bound would let an over-long reason reach the CHECK, fail the write and
  # leave the story sitting at `ci` with nothing recorded — the one outcome a fail-closed
  # gate cannot have. The margin is deliberate: the truncation is the LAST thing that may
  # cost an escalation its write.
  # 4000 is the CHECK; 3900 is what this writes, and the 100-codepoint margin is the point.
  @reason_budget 3_900

  @type fact(value) :: {:ok, value} | {:error, term()}

  @type facts :: %{
          required(:repo) => fact(String.t()),
          required(:pr_number) => fact(pos_integer()),
          required(:pull_request) => fact(map()),
          required(:head_files) => fact([String.t()]),
          required(:base_files) => fact([String.t()]),
          required(:triggers) => term(),
          required(:custody) => :ok | {:error, atom()},
          required(:recorded_head_sha) => String.t() | nil,
          required(:recorded_allow_sha) => String.t() | nil,
          optional(:trio_outputs) => term(),
          optional(:effect_proof) => map() | nil
        }

  @type error :: :not_found | :no_stage | :wrong_stage

  # The forge faults that mean "we could not tell", as opposed to a gate verdict: transport,
  # a 5xx, a 429, and the 403 GitHub answers a rate limit with. Every one of them clears on
  # its own, so the caller retries and the story STAYS at `ci`. Escalating on one would park
  # a story on a network blip until a human acts, and `escalated` is human-only.
  @transient_statuses [403, 408, 425, 429]

  @doc "The hard bound the design fixes, whatever the configuration says."
  @spec hard_bound() :: %{max_files: pos_integer(), max_changed_lines: pos_integer()}
  def hard_bound, do: %{max_files: @hard_max_files, max_changed_lines: @hard_max_changed_lines}

  @doc "The escalation edge a refusal takes, named here so a caller does not restate it."
  @spec escalation_transition() :: StageMachine.transition()
  def escalation_transition, do: {:ci, :escalated, :merge_gate}

  @doc """
  The whole decision, as a pure function of the facts. See the moduledoc for the shape of
  `facts`; every one of `:repo`, `:pr_number`, `:pull_request`, `:head_files` and
  `:base_files` is an `{:ok, value}` or an `{:error, reason}`, and an error is a refusal
  naming the reason rather than anything the gates then work around.
  """
  @spec judge(facts()) :: Verdict.t()
  def judge(facts) do
    gate_a = GateA.evaluate(Map.get(facts, :trio_outputs))
    custody = Map.get(facts, :custody, {:error, :custody_unknown})
    carried = gate_a_reasons(gate_a) ++ custody_reasons(custody)

    base = %Verdict{
      decision: :refuse,
      reasons: [],
      gate_a: gate_a,
      gate_a_inputs: :caller_asserted,
      custody: custody_code(custody),
      repo: value(facts, :repo),
      pr_number: value(facts, :pr_number)
    }

    # A transient forge fault is decided FIRST and decides everything: nothing was
    # evaluated, so nothing transitions. The reasons still carry whatever else is known —
    # a caller fixing custody should not have to wait for the forge to come back to hear
    # about it — but the DECISION is that there is no verdict yet.
    case {unevaluated_reasons(facts), input_reasons(facts)} do
      {[_ | _] = transient, other} ->
        %{base | decision: :unevaluated, reasons: Enum.uniq(transient ++ other ++ carried)}

      {[], [_ | _] = broken} ->
        refuse(base, broken ++ carried)

      {[], []} ->
        decide(base, facts, value(facts, :pull_request), carried)
    end
  end

  @doc """
  Gathers the facts for a story at the `ci` stage and judges them. Writes nothing.

  ## Options

  - `:trio_outputs` (required in practice) — the triage trio's three decoded output
    objects, Gate A's only input. Anything that is not exactly three well-formed outputs
    escalates, which is what makes an absent or forgotten value fail closed rather than pass
  - `:effect_proof` — `%{intent: _, fixture_set: _, fixture_results: _, coverage: _}` for a
    change that touches an effect path. Absent, a `:prove_effect` outcome is a refusal

  ## Errors

  `{:error, :not_found}` for a story that is not in the tenant, `{:error, :no_stage}` when
  it has no stage row, and `{:error, :wrong_stage}` when the row is not at `ci` — the only
  stage a merge is decided from, and the only one the `:merge_gate` edge leaves. These are
  the caller asking at the wrong moment, not verdicts about the change.
  """
  @spec evaluate(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, Verdict.t()} | {:error, error()}
  def evaluate(tenant_id, story_id, opts) do
    with {:ok, story} <- fetch_story(tenant_id, story_id),
         {:ok, stage} <- fetch_stage(tenant_id, story_id) do
      {:ok, story |> gather(stage, opts) |> judge()}
    end
  end

  @doc """
  `evaluate/3`, and on a refusal the escalation it implies: `{:ci, :escalated, :merge_gate}`
  through `Loopctl.Delivery.Stages`, with a reason naming every failure.

  Returns the verdict either way. An escalation that could not be written is LOGGED and
  reported on the verdict's reasons as `{:escalation_failed, reason}` — the refusal still
  stands, and a caller must never read a failed escalation as permission to merge.

  ## Options

  Every option of `evaluate/3`, plus:

  - `:claim_epoch` (required) — the epoch the caller acts under, fencing the escalation
    exactly as every other transition is fenced
  - `:actor_label`, `:actor_role`, `:actor_lineage` — attribution, server-resolved by the
    caller from the authenticating key
  """
  @spec enforce(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) :: {:ok, Verdict.t()} | {:error, error()}
  def enforce(tenant_id, story_id, opts) do
    with {:ok, verdict} <- evaluate(tenant_id, story_id, opts) do
      {:ok, act(tenant_id, story_id, verdict, opts)}
    end
  end

  # -- the judgement (pure) --------------------------------------------------------------

  @input_facts [
    {:repo, :repository_unresolved},
    {:pr_number, :no_pull_request_recorded},
    {:pull_request, :pull_request_unavailable}
  ]

  @forge_facts [
    {:pull_request, :pull_request_unavailable},
    {:head_files, :head_files_unavailable},
    {:base_files, :base_files_unavailable}
  ]

  # EVERY broken input, not the first. A refusal escalates, and after it the story is out
  # of `ci` and the gate cannot be re-run, so one reason where two are wrong sends a human
  # to fix half a problem. `:not_attempted` is dropped: it is the CONSEQUENCE of a missing
  # input listed alongside it, never a second fault.
  defp input_reasons(facts) do
    for {key, kind} <- @input_facts,
        reason = error_reason(facts, key),
        reason != :not_attempted,
        do: {kind, reason}
  end

  defp unevaluated_reasons(facts) do
    for {key, kind} <- @forge_facts,
        reason = error_reason(facts, key),
        transient?(reason),
        do: {kind, reason}
  end

  defp error_reason(facts, key) do
    case Map.get(facts, key) do
      {:ok, _value} -> nil
      {:error, reason} -> reason
      other -> {:missing_fact, shape(other)}
    end
  end

  @doc """
  True for a forge failure that means "we could not tell" rather than a gate verdict.

  Public because it is the whole difference between a story that waits for a retry and one
  parked on a human: transport, a 5xx, a 429, and the 403 GitHub answers a rate limit with.
  A 404, a 401, a body that does not parse and a truncated list are NOT transient — they
  are configuration or a contract change, and a human is the right answer to each.
  """
  @spec transient?(term()) :: boolean()
  def transient?({:github_unreachable, _reason}), do: true
  def transient?({:github_api_error, status}) when status >= 500, do: true
  def transient?({:github_api_error, status}), do: status in @transient_statuses
  def transient?(_reason), do: false

  defp value(facts, key) do
    case Map.get(facts, key) do
      {:ok, value} -> value
      _other -> nil
    end
  end

  # An ALREADY-MERGED pull request. The outward effect has happened, so the question is no
  # longer whether to merge but whether the gate ever AUTHORISED this merge — and the only
  # thing that can answer it is a recorded allow keyed to the head that was merged.
  defp decide(verdict, facts, %{merged?: true} = pr, carried) do
    verdict = %{
      verdict
      | head_sha: pr.head_sha,
        merge_sha: pr.merge_sha,
        diffstat: Map.get(pr, :diffstat)
    }

    case ungated_reasons(pr, Map.get(facts, :recorded_allow_sha)) do
      [] -> %{verdict | decision: :already_merged, reasons: []}
      reasons -> refuse(verdict, reasons ++ carried)
    end
  end

  defp decide(verdict, facts, pr, carried) do
    verdict = %{
      verdict
      | head_sha: Map.get(pr, :head_sha),
        merge_base_sha: Map.get(pr, :merge_base_sha),
        diffstat: Map.get(pr, :diffstat)
    }

    case head_moved_reasons(pr, Map.get(facts, :recorded_head_sha)) do
      [] -> gated(verdict, facts, pr, carried)
      moved -> %{verdict | decision: :head_moved, reasons: Enum.uniq(moved ++ carried)}
    end
  end

  defp gated(verdict, facts, pr, carried) do
    own = hard_bound_reasons(Map.get(pr, :diffstat)) ++ open_reasons(pr) ++ carried

    case gate_b(facts, pr) do
      {:ok, gate_b} ->
        proof = proof(gate_b, Map.get(facts, :effect_proof))
        verdict = %{verdict | gate_b: gate_b, proof: proof}

        case own ++ gate_b_reasons(gate_b, proof) do
          [] -> %{verdict | decision: :allow, reasons: []}
          reasons -> refuse(verdict, reasons)
        end

      {:refuse, reasons} ->
        refuse(verdict, reasons ++ own)
    end
  end

  # A merge nobody authorised. The sha is still reported on the verdict and named in the
  # reason, so the fact is not lost — but the decision is a REFUSAL, because the last gate
  # before an outward effect must never report clean for an effect it did not license.
  defp ungated_reasons(%{merge_sha: nil}, _allowed),
    do: [:merged_without_sha]

  defp ungated_reasons(%{merge_sha: merge_sha, head_sha: head}, allowed) do
    cond do
      is_nil(allowed) -> [{:ungated_merge, merge_sha, :no_recorded_allow}]
      allowed == head -> []
      true -> [{:ungated_merge, merge_sha, {:allow_for_other_head, allowed}}]
    end
  end

  defp ungated_reasons(pr, _allowed), do: [{:unreadable_pull_request, shape(pr)}]

  # The head the gate is about to judge must be the head CI ran on and the story was
  # verified at. A push after either is ordinary work, not an escalation, so it goes back
  # to `implementing` — but it does NOT merge, because no CI run and no verifier saw it.
  defp head_moved_reasons(%{head_sha: head}, recorded) do
    cond do
      is_nil(recorded) -> [:head_sha_not_recorded]
      recorded == head -> []
      true -> [{:head_moved, head, recorded}]
    end
  end

  defp head_moved_reasons(_pr, _recorded), do: [:head_sha_not_recorded]

  defp refuse(verdict, reasons), do: %{verdict | decision: :refuse, reasons: Enum.uniq(reasons)}

  # A pull request that is neither open nor merged was closed without merging; there is
  # nothing to gate and nothing to adopt, so it escalates rather than reporting a clean run.
  defp open_reasons(%{state: "open"}), do: []
  defp open_reasons(%{state: state}), do: [{:pr_not_open, state}]
  defp open_reasons(_pr), do: [:unreadable_pull_request_state]

  defp gate_a_reasons(%GateA.Result{decision: :escalate, reasons: reasons}),
    do: Enum.map(reasons, &{:gate_a, &1})

  defp gate_a_reasons(%GateA.Result{verdict: :story}), do: []
  defp gate_a_reasons(%GateA.Result{verdict: verdict}), do: [{:trio_verdict, verdict}]

  defp gate_b_reasons(%GateB.Result{outcome: :clear}, _proof), do: []

  defp gate_b_reasons(%GateB.Result{outcome: :human, reasons: reasons}, _proof),
    do: Enum.map(reasons, &{:gate_b, &1})

  defp gate_b_reasons(%GateB.Result{outcome: :prove_effect}, nil), do: [:effect_proof_required]

  # A PASSING proof does NOT clear the gate today, and that is deliberate. The proof is a
  # caller assertion supplied by the same principal that drives the merge, so accepting it
  # would let a fabricated one turn an effect path into an allow — the change most in need
  # of a gate would be the easiest to wave through. It is recorded and it escalates.
  # What closes this: the design's own Gate B harness (build order step 2) — deploy to
  # staging, regenerate 837P output from the fixed fixture set server-side, and judge THAT.
  # Then the proof is loopctl's measurement rather than the caller's claim, and this clause
  # becomes `[]`.
  defp gate_b_reasons(%GateB.Result{outcome: :prove_effect}, %GateB.ProofResult{verdict: :pass}),
    do: [{:effect_proof_caller_asserted, :pass}]

  defp gate_b_reasons(%GateB.Result{outcome: :prove_effect}, %GateB.ProofResult{
         failures: failures
       }),
       do: Enum.map(failures, &{:effect_proof, &1})

  defp proof(%GateB.Result{outcome: :prove_effect}, effect_proof) do
    case effect_proof do
      %{intent: intent, fixture_set: set, fixture_results: results, coverage: coverage} ->
        DeliveryGates.judge_proof(intent, set, results, coverage)

      nil ->
        nil

      other ->
        %GateB.ProofResult{
          verdict: :fail,
          failures: [{:invalid_effect_proof, shape(other)}],
          route: :gate_a
        }
    end
  end

  defp proof(_gate_b, _effect_proof), do: nil

  # The design's ceiling, applied to the FORGE's own diffstat and independent of the
  # configured limits Gate B already applied. `max(count, listed)` is Gate B's business;
  # here the authoritative totals are what a merge is bounded by, so a file list the forge
  # truncated cannot shrink the bound that judges the change.
  defp hard_bound_reasons(%{files: files, changed_lines: lines})
       when is_integer(files) and is_integer(lines) do
    files_reason =
      if files > @hard_max_files,
        do: [{:hard_bound_files_exceeded, files, @hard_max_files}],
        else: []

    lines_reason =
      if lines > @hard_max_changed_lines,
        do: [{:hard_bound_changed_lines_exceeded, lines, @hard_max_changed_lines}],
        else: []

    files_reason ++ lines_reason
  end

  defp hard_bound_reasons(diffstat), do: [{:invalid_diffstat, shape(diffstat)}]

  defp custody_reasons(:ok), do: []
  defp custody_reasons({:error, reason}), do: [{:custody, reason}]
  defp custody_reasons(other), do: [{:custody, {:unreadable, shape(other)}}]

  defp custody_code(:ok), do: :ok
  defp custody_code({:error, reason}), do: reason
  defp custody_code(_other), do: :custody_unknown

  # -- Gate B, at both refs (pure) -------------------------------------------------------

  @ref_facts [
    {:head_files, :head_files_unavailable},
    {:base_files, :base_files_unavailable}
  ]

  # BOTH file lists, and both failures if both are broken: the stale-trigger guard is only
  # meaningful when it has seen both refs, so a caller told about one unreadable ref would
  # fix it and be told about the other on a story it can no longer re-run the gate for.
  defp gate_b(facts, pr) do
    case for({key, kind} <- @ref_facts, r = error_reason(facts, key), do: {kind, r}) do
      [] ->
        triggers = Map.get(facts, :triggers)
        repo = value(facts, :repo)

        at_head = evaluate_gate_b(repo, pr, value(facts, :head_files), triggers)
        at_base = evaluate_gate_b(repo, pr, value(facts, :base_files), triggers)

        {:ok, merge_results(at_head, at_base)}

      reasons ->
        {:refuse, reasons}
    end
  end

  defp evaluate_gate_b(repo, pr, repo_files, triggers) do
    input =
      DiffNames.merge_input(Map.get(pr, :diff), %{
        repo: repo,
        repo_files: repo_files,
        diffstat: Map.get(pr, :diffstat)
      })

    DeliveryGates.gate_b(:merge, input, triggers)
  end

  # OR, never AND: a refusal at either ref is a refusal.
  defp merge_results(%GateB.Result{} = a, %GateB.Result{} = b) do
    %GateB.Result{
      phase: :merge,
      outcome: worst(a.outcome, b.outcome),
      merge_precondition?: true,
      reasons: Enum.uniq(a.reasons ++ b.reasons),
      effect_matches: Enum.uniq(a.effect_matches ++ b.effect_matches)
    }
  end

  defp worst(a, b) do
    cond do
      :human in [a, b] -> :human
      :prove_effect in [a, b] -> :prove_effect
      true -> :clear
    end
  end

  # -- gathering the facts ---------------------------------------------------------------

  defp gather(story, stage, opts) do
    repo = repo_for_story(story)
    pr_number = pr_number(stage)
    pull_request = pull_request(repo, pr_number)

    %{
      repo: repo,
      pr_number: pr_number,
      pull_request: pull_request,
      head_files: repo_files(repo, pull_request, :head_sha),
      base_files: repo_files(repo, pull_request, :merge_base_sha),
      triggers: DeliveryGates.load_triggers(),
      custody: Progress.merge_custody_status(story),
      # The head CI ran on and the story was verified at, and the head a previous allow was
      # granted for. Both are read from the stage row, never from the caller.
      recorded_head_sha: stage.head_sha,
      recorded_allow_sha: stage.merge_gate_allowed_sha,
      trio_outputs: Keyword.get(opts, :trio_outputs),
      effect_proof: Keyword.get(opts, :effect_proof)
    }
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
      %{stage: :ci} = stage -> {:ok, stage}
      %{stage: _other} -> {:error, :wrong_stage}
    end
  end

  defp pr_number(%{pr_number: number}) when is_integer(number) and number > 0, do: {:ok, number}
  defp pr_number(%{pr_number: number}), do: {:error, {:not_recorded, number}}

  defp pull_request({:ok, repo}, {:ok, number}), do: source().pull_request(repo, number)
  defp pull_request(_repo, _number), do: {:error, :not_attempted}

  defp repo_files({:ok, repo}, {:ok, pr}, key) do
    case Map.get(pr, key) do
      ref when is_binary(ref) -> source().repo_files(repo, ref)
      other -> {:error, {:missing_ref, key, shape(other)}}
    end
  end

  defp repo_files(_repo, _pull_request, _key), do: {:error, :not_attempted}

  # The repository is NEVER taken from the caller. Gate B's trigger list is keyed by
  # repository, so a caller that could name one could name a DIFFERENT configured
  # repository and be judged against the wrong trigger list. It is resolved from the
  # story's project through its GitHub intake source, and a project with no source, or with
  # more than one, refuses rather than guessing.
  defp repo_for_story(%{tenant_id: tenant_id, project_id: project_id}) do
    tenant_id
    |> Intake.list_sources()
    |> Enum.filter(&(&1.project_id == project_id))
    |> case do
      [source] -> {:ok, source.repo_full_name}
      [] -> {:error, {:no_intake_source, project_id}}
      sources -> {:error, {:ambiguous_intake_source, project_id, length(sources)}}
    end
  end

  defp source do
    Application.get_env(
      :loopctl,
      :delivery_pull_request_source,
      Loopctl.Delivery.GitHubPullRequestSource
    )
  end

  # -- the one write ---------------------------------------------------------------------

  # `:unevaluated` and `:already_merged` transition NOTHING. `:unevaluated` because there is
  # no verdict to act on and a network blip must not park a story on a human; an authorised
  # `:already_merged` because the caller's next act is recording the merge it adopted.
  defp act(_tenant_id, _story_id, %Verdict{decision: decision} = verdict, _opts)
       when decision in [:unevaluated, :already_merged],
       do: verdict

  defp act(tenant_id, story_id, %Verdict{decision: :allow} = verdict, opts) do
    record_allow(tenant_id, story_id, verdict, opts)
  end

  defp act(tenant_id, story_id, %Verdict{decision: :head_moved} = verdict, opts) do
    transition(tenant_id, story_id, verdict, {:ci, :implementing, :base_moved}, opts)
  end

  defp act(tenant_id, story_id, %Verdict{decision: :refuse} = verdict, opts) do
    transition(tenant_id, story_id, verdict, escalation_transition(), opts)
  end

  # An allow is a RECORDED fact or it is not an allow. Without this the gate's authorisation
  # lives only in the response, and an already-merged pull request cannot be told from one
  # merged around the gate — so a write that does not land turns the allow into a refusal
  # rather than a merge nobody can later account for.
  defp record_allow(tenant_id, story_id, %Verdict{head_sha: head} = verdict, opts) do
    write_opts = Keyword.take(opts, [:claim_epoch, :actor_label])

    case Stages.record_effect(tenant_id, story_id, :merge_gate_allowed_sha, head, write_opts) do
      {:ok, _row} ->
        verdict

      {:error, reason} ->
        Logger.warning(
          "merge_gate allow not recorded story_id=#{story_id} tenant_id=#{tenant_id} " <>
            "head=#{inspect(head)} reason=#{inspect(reason)}"
        )

        refuse(verdict, [{:allow_not_recorded, reason}])
    end
  end

  defp transition(tenant_id, story_id, %Verdict{} = verdict, {_from, to, edge} = target, opts) do
    advance_opts =
      opts
      |> Keyword.take([:claim_epoch, :actor_label, :actor_role, :actor_lineage])
      |> Keyword.put(:reason, reason_text(verdict))

    case Stages.advance(tenant_id, story_id, target, advance_opts) do
      {:ok, _row} ->
        verdict

      {:error, reason} ->
        Logger.warning(
          "merge_gate #{to}/#{edge} not written story_id=#{story_id} tenant_id=#{tenant_id} " <>
            "reason=#{inspect(reason)} verdict_reasons=#{inspect(verdict.reasons)}"
        )

        %{verdict | reasons: verdict.reasons ++ [{:transition_failed, to, edge, reason}]}
    end
  end

  # Bounded by the `story_stages_text_bounds` CHECK. A refusal with a long reason list must
  # still WRITE its escalation: a reason too long to store would roll the transition back
  # and leave the story sitting at `ci` with nothing recorded, which is the one outcome a
  # fail-closed gate cannot have.
  defp reason_text(%Verdict{reasons: reasons, gate_a_inputs: gate_a_inputs}) do
    bound_codepoints(
      "merge_gate (gate_a inputs: #{gate_a_inputs}): " <>
        Enum.map_join(reasons, "; ", &inspect/1)
    )
  end

  # CODEPOINTS, matching Postgres `char_length` and `Stages`' own bound — see the note on
  # `@reason_budget`. A codepoint prefix can split a grapheme cluster; that is cosmetic and
  # the string stays valid UTF-8, which is the trade against an escalation that will not
  # write at all.
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
  defp shape(value) when is_integer(value), do: value
  defp shape(_value), do: :unreadable
end
