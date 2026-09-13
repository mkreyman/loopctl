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
  2. **Gate B** (`Loopctl.DeliveryGates.gate_b/3`) at `:merge` — `:clear`, or
     `:prove_effect` cleared by an effect proof this call carried
     (`Loopctl.DeliveryGates.judge_proof/4`; a proof that FAILS routes to Gate A, and a
     `:prove_effect` with NO proof is a refusal, never a pass).
  3. **The design's hard bound** — 12 files, 1,000 changed lines — applied on TOP of the
     configured limits, so a configuration that raises `max_files` cannot raise this. It is
     applied to the FORGE's own diffstat, never to the length of a file list that may have
     been truncated.
  4. **Custody** (design §9) — `verified_status: :verified`, set through a verifier
     dispatch whose lineage is separate from the implementer's. That comparison is
     `Loopctl.Progress.merge_custody_status/1`, which is the L4 gate `verify` already runs;
     there is no second lineage comparison here.

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

  A pull request the forge reports as ALREADY MERGED is `:already_merged`, not a refusal
  and not an allow: the outward effect has happened, so there is nothing left to gate. A
  caller that crashed between merging and recording the merge adopts `merge_sha` and
  advances, instead of being told its own completed merge is an escalation.

  ## The one write, and no second write path

  A refusal takes `{:ci, :escalated, :merge_gate}` through `Loopctl.Delivery.Stages`, the
  only writer of `story_stages`. An allow writes nothing at all: the CALLER performs the
  merge and then advances `{:ci, :merged}` carrying the sha the forge returned, because the
  merge commit does not exist until the merge happens.
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

  # The `story_stages_text_bounds` CHECK on `escalation_reason`.
  @max_reason_chars 4_000

  @type fact(value) :: {:ok, value} | {:error, term()}

  @type facts :: %{
          required(:repo) => fact(String.t()),
          required(:pr_number) => fact(pos_integer()),
          required(:pull_request) => fact(map()),
          required(:head_files) => fact([String.t()]),
          required(:base_files) => fact([String.t()]),
          required(:triggers) => term(),
          required(:custody) => :ok | {:error, atom()},
          optional(:trio_outputs) => term(),
          optional(:effect_proof) => map() | nil
        }

  @type error :: :not_found | :no_stage | :wrong_stage

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
      custody: custody_code(custody)
    }

    case inputs(facts) do
      {:ok, repo, pr_number, pr} ->
        decide(%{base | repo: repo, pr_number: pr_number}, facts, pr, carried)

      {:refuse, reason} ->
        refuse(base, [reason | carried])
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
      {:ok, escalate(tenant_id, story_id, verdict, opts)}
    end
  end

  # -- the judgement (pure) --------------------------------------------------------------

  defp inputs(facts) do
    with {:ok, repo} <- fact(facts, :repo, :repository_unresolved),
         {:ok, pr_number} <- fact(facts, :pr_number, :no_pull_request_recorded),
         {:ok, pr} <- fact(facts, :pull_request, :pull_request_unavailable) do
      {:ok, repo, pr_number, pr}
    end
  end

  defp fact(facts, key, kind) do
    case Map.get(facts, key) do
      {:ok, value} -> {:ok, value}
      {:error, reason} -> {:refuse, {kind, reason}}
      other -> {:refuse, {kind, {:missing_fact, other}}}
    end
  end

  defp decide(verdict, _facts, %{merged?: true} = pr, _carried) do
    %{
      verdict
      | decision: :already_merged,
        reasons: [],
        head_sha: pr.head_sha,
        merge_sha: pr.merge_sha,
        diffstat: pr.diffstat
    }
  end

  defp decide(verdict, facts, pr, carried) do
    verdict = %{
      verdict
      | head_sha: Map.get(pr, :head_sha),
        merge_base_sha: Map.get(pr, :merge_base_sha),
        diffstat: Map.get(pr, :diffstat)
    }

    own = hard_bound_reasons(Map.get(pr, :diffstat)) ++ open_reasons(pr) ++ carried

    case gate_b(facts, pr) do
      {:ok, gate_b} ->
        proof = proof(gate_b, Map.get(facts, :effect_proof))
        verdict = %{verdict | gate_b: gate_b, proof: proof}

        case own ++ gate_b_reasons(gate_b, proof) do
          [] -> %{verdict | decision: :allow, reasons: []}
          reasons -> refuse(verdict, reasons)
        end

      {:refuse, reason} ->
        refuse(verdict, [reason | own])
    end
  end

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

  defp gate_b_reasons(%GateB.Result{outcome: :prove_effect}, %GateB.ProofResult{verdict: :pass}),
    do: []

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

  defp gate_b(facts, pr) do
    with {:ok, head_files} <- fact(facts, :head_files, :head_files_unavailable),
         {:ok, base_files} <- fact(facts, :base_files, :base_files_unavailable) do
      triggers = Map.get(facts, :triggers)
      repo = repo_of(facts)

      at_head = evaluate_gate_b(repo, pr, head_files, triggers)
      at_base = evaluate_gate_b(repo, pr, base_files, triggers)

      {:ok, merge_results(at_head, at_base)}
    end
  end

  defp repo_of(%{repo: {:ok, repo}}), do: repo
  defp repo_of(_facts), do: nil

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

  defp escalate(_tenant_id, _story_id, %Verdict{decision: decision} = verdict, _opts)
       when decision != :refuse,
       do: verdict

  defp escalate(tenant_id, story_id, %Verdict{} = verdict, opts) do
    advance_opts =
      opts
      |> Keyword.take([:claim_epoch, :actor_label, :actor_role, :actor_lineage])
      |> Keyword.put(:reason, reason_text(verdict))

    case Stages.advance(tenant_id, story_id, escalation_transition(), advance_opts) do
      {:ok, _row} ->
        verdict

      {:error, reason} ->
        Logger.warning(
          "merge_gate escalation not written story_id=#{story_id} tenant_id=#{tenant_id} " <>
            "reason=#{inspect(reason)} verdict_reasons=#{inspect(verdict.reasons)}"
        )

        %{verdict | reasons: verdict.reasons ++ [{:escalation_failed, reason}]}
    end
  end

  # Bounded by the `story_stages_text_bounds` CHECK. A refusal with a long reason list must
  # still WRITE its escalation: a reason too long to store would roll the transition back
  # and leave the story sitting at `ci` with nothing recorded, which is the one outcome a
  # fail-closed gate cannot have.
  defp reason_text(%Verdict{reasons: reasons}) do
    text = "merge_gate: " <> Enum.map_join(reasons, "; ", &inspect/1)

    if String.length(text) > @max_reason_chars,
      do: String.slice(text, 0, @max_reason_chars - 1) <> "…",
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
