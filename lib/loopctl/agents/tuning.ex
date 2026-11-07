defmodule Loopctl.Agents.Tuning do
  @moduledoc """
  The improvement loop (Epic 48, US-48.13): `spec_tuner@1`'s pass, its effect, and the
  operator's read and landed-marking of what it stored.

  ## What the loop is, and what it is not allowed to do

  For a target spec in a project whose run-outcome ledger (US-48.12) has gathered
  `SpecTunerV1.min_outcome_rows/0` rows since its last answered tuning run, the pass sends ONE
  `spec_tune` dispatch carrying that spec's FAILED runs as traces. The runner's session proposes
  a new version of the target's prompt template and the eval cases that would have caught the
  failures, runs the eval harness over both templates, and answers with one `agent_result`.

  loopctl stores the answer and DECIDES ITS STATUS ITSELF (`decide/2`): `proposed` only when
  the proposed template strictly beats the current one on the recomputed per-case results AND
  no existing case regresses, `rejected` otherwise, with the reasons. It never edits a template
  and never flips a spec version (AC-48.13.4): those are code, changed by a pull request a
  person merges, after which an operator marks the draft `landed` (`mark_landed/4`).
  `test/loopctl/agents/tuning_no_self_edit_test.exs` scans `lib/` for any other writer.

  ## A tuning dispatch has no story

  Its subject is a (project, target spec) pair, so its ledger row carries no `story_id`
  (contract 1.30.0) and `claim_epoch` 0. The concurrency is the draft table's own: the pass
  inserts a `pending` row before it sends, and `spec_tuning_drafts_pending_uidx` admits one per
  pair, so two passes racing on a pair cannot both dispatch. A pending row whose dispatch ended
  without an answer is `abandoned` by the next pass (`abandon_stale/1`), which frees the pair.

  ## What a trace is

  One outcome row of the target spec in the window that carries a failure: a human overrode it
  (`human_override`), its session hit a budget, the merge gate refused its work, its merge was
  refused, CI went red, its review found at least `SpecTunerV1.review_findings_high/0` issues,
  or its draft was refused. Every field is loopctl's own value — the failure codes, the agent's
  recorded outcome, the human's route and the outcomes that lead there — except `untrusted`:
  the story's text (its intake record's reporter text, else its title and description) rendered
  by `Loopctl.Delivery.Untrusted.render/2`, the fence triage uses, so text a stranger wrote
  reaches the tuning session only as data. The trace id is the dispatch id of the run.

  A new eval case names its trace and carries no input of its own: the case's input is the
  trace loopctl sent and stored on the draft. Where the trace carries a human decision, the
  case must expect exactly that decision's outcomes, or the draft is rejected.

  ## Switches

  The pass runs only when BOTH `DispatchDriver.enabled?/0` (`DISPATCH_DRIVER_ENABLED`) and
  `Dispatcher.drafts_enabled?/0` (`DRAFT_DISPATCH_ENABLED`) are on: a tuning run is a `:draft`,
  and stores an artifact a person releases. A halted tenant is refused by `Runners.dispatch/3`
  before anything is recorded, and its pending row is deleted.
  """

  import Ecto.Query

  require Logger

  alias Loopctl.AdminRepo
  alias Loopctl.Agents.Dispatcher
  alias Loopctl.Agents.Outcomes
  alias Loopctl.Agents.Registry
  alias Loopctl.Agents.RunOutcome
  alias Loopctl.Agents.Spec
  alias Loopctl.Agents.Specs.SpecTunerV1
  alias Loopctl.Agents.TuningDraft
  alias Loopctl.ApiSpec.RunnerContract.ByteRule
  alias Loopctl.ApiSpec.RunnerContract.RunnerSpecTune
  alias Loopctl.Audit
  alias Loopctl.Delivery.DispatchDriver
  alias Loopctl.Delivery.RunnerStages
  alias Loopctl.Delivery.Untrusted
  alias Loopctl.GitRef
  alias Loopctl.Intake
  alias Loopctl.Intake.Record
  alias Loopctl.KeysetCursor
  alias Loopctl.Repo
  alias Loopctl.Runners
  alias Loopctl.Runners.DispatchRecord
  alias Loopctl.Runners.Runner
  alias Loopctl.WorkBreakdown.Story

  @cursor_namespace "tuning_draft_cursor"
  @default_limit 50
  @max_limit 100

  # The outcome rows of one window a trace set is chosen from, newest first. A bound on the
  # read, not on what is learned: at most `RunnerSpecTune.max_traces/0` traces are sent.
  @max_rows_read 500

  # The raw story text one trace starts from, cut BEFORE it is fenced (the fence's closing line
  # lives at the end, so cutting a rendered block would leave it unterminated). Shrunk further
  # when the rendered block exceeds `RunnerSpecTune.max_untrusted_length/0`.
  @untrusted_raw_chars 1_000

  # A pending row older than this whose dispatch holds no slot ended unanswered.
  @pending_grace_seconds 86_400

  @answered_statuses [:proposed, :rejected, :landed, :superseded]

  # A function, not an attribute: an OTP 28 regex cannot be escaped into a module attribute.
  defp pr_url_format,
    do:
      ~r"\Ahttps://github\.com/[A-Za-z0-9_.-]{1,100}/[A-Za-z0-9_.-]{1,100}/pull/[1-9][0-9]{0,9}\z"

  @typedoc "One (tenant, project, target spec) a tuning run is due for."
  @type candidate :: %{
          tenant_id: Ecto.UUID.t(),
          project_id: Ecto.UUID.t(),
          spec_id: String.t(),
          outcome_rows: non_neg_integer(),
          since: DateTime.t() | nil
        }

  @type outcome ::
          :dispatched
          | :no_runner
          | :nothing_to_learn
          | :already_pending
          | :deferred
          | :blocked
          | :errored

  @typedoc "One page of `list/2`."
  @type page :: %{
          data: [TuningDraft.t()],
          has_more: boolean(),
          next_cursor: KeysetCursor.position() | nil
        }

  # ── the pass ───────────────────────────────────────────────────────────────────────────────

  @doc """
  One tuning pass with `spec_tuner@1` (or `opts[:spec]`): abandons stale pending drafts, then
  dispatches at most `opts[:limit]` (required) due candidates. `{:ok, outcomes}`, `{:ok, []}`
  when the switches are off, or the budget error `Dispatcher.budgets/1` returns.

  Options: `:limit`, `:enabled?` (overrides the two switches), `:budgets`, `:dispatch`
  (defaults to `&Loopctl.Runners.dispatch/3`; the seam is the push, never an identity), `:now`.
  """
  @spec run(keyword()) :: {:ok, [{candidate(), outcome()}]} | {:error, term()}
  def run(opts) when is_list(opts) do
    spec = Keyword.get(opts, :spec, SpecTunerV1.spec())
    limit = Keyword.fetch!(opts, :limit)
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    enabled? =
      Keyword.get_lazy(opts, :enabled?, fn ->
        DispatchDriver.enabled?() and Dispatcher.drafts_enabled?()
      end)

    with true <- enabled? == true || :disabled,
         {:ok, budgets} <- fetch_budgets(spec, opts) do
      _ = abandon_stale(now)

      pass = %{
        spec: spec,
        budgets: budgets,
        dispatch: Keyword.get(opts, :dispatch, &Runners.dispatch/3),
        now: now
      }

      outcomes =
        for candidate <- candidates(limit, min_rows: Keyword.get(opts, :min_rows)),
            do: {candidate, attempt(pass, candidate)}

      {:ok, outcomes}
    else
      :disabled -> {:ok, []}
      {:error, _reason} = error -> error
    end
  end

  defp fetch_budgets(spec, opts) do
    case Keyword.fetch(opts, :budgets) do
      {:ok, budgets} -> {:ok, budgets}
      :error -> Dispatcher.budgets(spec)
    end
  end

  @doc """
  The target specs a tuning run may learn about: every registry spec but the tuner's own kind,
  so the loop never proposes changes to itself from its own runs.
  """
  @spec targets() :: [Spec.t()]
  def targets, do: Enum.reject(Registry.all(), &(&1.kind in tuner_kinds()))

  defp tuner_kinds,
    do: for(%Spec{effects: e, kind: k} <- Registry.all(), :tuning_draft in e, do: k)

  @doc """
  The due candidates, at most `limit`, fleet-wide on `AdminRepo` with an explicit tenant
  predicate on every join: a (tenant, project, target spec) with at least `:min_rows` (default
  `SpecTunerV1.min_outcome_rows/0`) outcome rows since its latest ANSWERED draft's
  `window_until`, and no pending draft. Ranked so every tenant's first pair comes before any
  tenant's second, most rows first within a tenant.
  """
  @spec candidates(pos_integer(), keyword()) :: [candidate()]
  def candidates(limit, opts \\ []) when is_integer(limit) and limit > 0 do
    min_rows = Keyword.get(opts, :min_rows) || SpecTunerV1.min_outcome_rows()
    target_ids = Enum.map(targets(), & &1.id)

    last =
      from d in TuningDraft,
        where: d.status in ^@answered_statuses,
        group_by: [d.tenant_id, d.project_id, d.target_spec_id],
        select: %{
          tenant_id: d.tenant_id,
          project_id: d.project_id,
          spec_id: d.target_spec_id,
          until: max(d.window_until)
        }

    pending =
      from d in TuningDraft,
        where: d.status == :pending,
        where: d.tenant_id == parent_as(:outcome).tenant_id,
        where: d.project_id == parent_as(:outcome).project_id,
        where: d.target_spec_id == parent_as(:outcome).spec_id,
        select: 1

    from(o in RunOutcome,
      as: :outcome,
      left_join: l in subquery(last),
      on: l.tenant_id == o.tenant_id and l.project_id == o.project_id and l.spec_id == o.spec_id,
      where: not is_nil(o.project_id) and o.spec_id in ^target_ids,
      where: is_nil(l.until) or o.inserted_at > l.until,
      where: not exists(pending),
      group_by: [o.tenant_id, o.project_id, o.spec_id],
      having: count(o.id) >= ^min_rows,
      select: %{
        tenant_id: o.tenant_id,
        project_id: o.project_id,
        spec_id: o.spec_id,
        outcome_rows: count(o.id),
        since: max(l.until)
      }
    )
    |> AdminRepo.all()
    |> round_robin(limit)
  end

  defp round_robin(rows, limit) do
    rows
    |> Enum.group_by(& &1.tenant_id)
    |> Enum.sort_by(fn {tenant_id, _rows} -> tenant_id end)
    |> Enum.flat_map(fn {_tenant, rows} ->
      rows
      |> Enum.sort_by(&{-&1.outcome_rows, &1.project_id, &1.spec_id})
      |> Enum.with_index()
    end)
    |> Enum.sort_by(fn {row, rank} -> {rank, row.tenant_id} end)
    |> Enum.map(fn {row, _rank} -> row end)
    |> Enum.take(limit)
  end

  # ONE CANDIDATE MAY NOT KILL THE PASS.
  defp attempt(pass, candidate) do
    with {:ok, target} <- target_spec(candidate.spec_id),
         {:ok, source} <- Intake.source_for_project(candidate.tenant_id, candidate.project_id),
         :ok <- usable_base_branch(source.base_branch),
         {:ok, object} <- input(candidate, target, pass.now),
         [%Runner{} = runner | _] <-
           Dispatcher.runners(pass.spec, candidate.tenant_id, source.repo_full_name) do
      send_tuning(pass, candidate, %{target: target, source: source, runner: runner}, object)
    else
      [] -> :no_runner
      {:error, :nothing_to_learn} -> :nothing_to_learn
      {:error, reason} -> blocked(candidate, reason)
    end
  rescue
    error -> errored(candidate, Exception.format(:error, error, __STACKTRACE__))
  end

  defp target_spec(spec_id) do
    case Enum.find(targets(), &(&1.id == spec_id)) do
      %Spec{} = spec -> {:ok, spec}
      nil -> {:error, :unknown_target_spec}
    end
  end

  defp usable_base_branch(branch) do
    if is_binary(branch) and GitRef.valid_name?(branch) and byte_size(branch) <= 255,
      do: :ok,
      else: {:error, :invalid_base_branch}
  end

  # The pending row FIRST, holding the pair; then the push. A refused push deletes the row it
  # inserted — `Runners.dispatch/3` records nothing on any refusal, so no ledger row can name
  # the deleted draft's dispatch.
  defp send_tuning(pass, candidate, %{target: target, source: source, runner: runner}, object) do
    dispatch_id = Ecto.UUID.generate()

    case insert_pending(candidate, target, dispatch_id, object, pass.now) do
      {:ok, draft} ->
        payload = %{
          "dispatch_id" => dispatch_id,
          "kind" => pass.spec.kind,
          "repo" => source.repo_full_name,
          "base_branch" => source.base_branch,
          "branch" => source.base_branch,
          "claim_epoch" => 0,
          "wall_clock_seconds" => pass.budgets.wall_clock_seconds,
          "max_turns" => pass.budgets.max_turns,
          "spec_tune" => object
        }

        case pass.dispatch.(candidate.tenant_id, runner.id, payload) do
          :ok ->
            :dispatched

          {:error, reason} ->
            delete_pending(draft)
            refused(candidate, reason)
        end

      {:error, :already_pending} ->
        :already_pending
    end
  end

  @transient [
    :runner_not_connected,
    :runner_ambiguous,
    :runner_exhausted,
    :admission_limit_reached,
    :runner_at_capacity,
    :capacity_busy,
    :tenant_halted
  ]

  defp refused(_candidate, reason) when reason in [:runner_exhausted], do: :no_runner
  defp refused(candidate, reason) when reason in @transient, do: deferred(candidate, reason)
  defp refused(candidate, reason), do: blocked(candidate, reason)

  defp deferred(candidate, reason) do
    Logger.info("SpecTunerDispatcher: deferred #{describe(candidate)} reason=#{inspect(reason)}")
    :deferred
  end

  defp blocked(candidate, reason) do
    Logger.warning(
      "SpecTunerDispatcher: blocked #{describe(candidate)} reason=#{inspect(reason)}",
      tenant_id: candidate.tenant_id
    )

    :blocked
  end

  defp errored(candidate, detail) do
    Logger.error("SpecTunerDispatcher: errored #{describe(candidate)}\n" <> detail,
      tenant_id: candidate.tenant_id
    )

    :errored
  end

  defp describe(candidate),
    do:
      "tenant_id=#{candidate.tenant_id} project_id=#{candidate.project_id} " <>
        "spec_id=#{candidate.spec_id}"

  defp insert_pending(candidate, target, dispatch_id, object, now) do
    {template_id, template_version} = target.prompt

    row = %{
      id: Ecto.UUID.generate(),
      tenant_id: candidate.tenant_id,
      project_id: candidate.project_id,
      dispatch_id: dispatch_id,
      target_spec_id: target.id,
      target_spec_version: target.version,
      template_id: template_id,
      from_version: template_version,
      eval_set: eval_set(target),
      status: :pending,
      window_since: candidate.since,
      window_until: now,
      outcome_rows: candidate.outcome_rows,
      input: object,
      rejection_reasons: [],
      inserted_at: now,
      updated_at: now
    }

    # `ON CONFLICT DO NOTHING` on the partial unique index: a pair already pending inserts
    # nothing, and the statement never fails, so the transaction never aborts on the race.
    {:ok, {count, _rows}} =
      Repo.with_tenant(candidate.tenant_id, fn ->
        Repo.insert_all(TuningDraft, [row],
          on_conflict: :nothing,
          conflict_target:
            {:unsafe_fragment, "(tenant_id, project_id, target_spec_id) WHERE status = 'pending'"}
        )
      end)

    case count do
      1 -> {:ok, struct(TuningDraft, row)}
      0 -> {:error, :already_pending}
    end
  end

  defp delete_pending(%TuningDraft{} = draft) do
    {:ok, _count} =
      Repo.with_tenant(draft.tenant_id, fn ->
        from(d in TuningDraft,
          where: d.tenant_id == ^draft.tenant_id and d.id == ^draft.id and d.status == :pending
        )
        |> Repo.delete_all()
      end)

    :ok
  end

  @doc """
  Marks `abandoned` every pending draft older than #{@pending_grace_seconds} seconds at `now`
  whose dispatch holds no slot (released, or never recorded): its session ended without an
  answer, and the pair is free for the next pass. Fleet-wide on `AdminRepo`, tenant-joined.
  """
  @spec abandon_stale(DateTime.t()) :: non_neg_integer()
  def abandon_stale(%DateTime{} = now) do
    cutoff = DateTime.add(now, -@pending_grace_seconds, :second)

    live =
      from r in DispatchRecord,
        where: r.tenant_id == parent_as(:draft).tenant_id,
        where: r.dispatch_id == parent_as(:draft).dispatch_id,
        where: is_nil(r.released_at),
        select: 1

    {count, _} =
      from(d in TuningDraft,
        as: :draft,
        where: d.status == :pending and d.inserted_at < ^cutoff,
        where: not exists(live)
      )
      |> AdminRepo.update_all(set: [status: :abandoned, updated_at: now])

    count
  end

  # ── the input ──────────────────────────────────────────────────────────────────────────────

  @doc "The eval set a target spec is scored over: `\"<id>@<version>\"`."
  @spec eval_set(Spec.t()) :: String.t()
  def eval_set(%Spec{id: id, version: version}), do: "#{id}@#{version}"

  @doc """
  The `spec_tune` object (`RunnerSpecTune`, string keys) for `candidate` and its `target` spec
  over the window ending at `now`, or `{:error, :nothing_to_learn}` when the window holds no
  failed run. Newest failures first, at most `RunnerSpecTune.max_traces/0`, dropped from the
  oldest until the object fits `RunnerSpecTune.max_bytes/0` under the byte rule.
  """
  @spec input(candidate(), Spec.t(), DateTime.t()) :: {:ok, map()} | {:error, :nothing_to_learn}
  def input(candidate, %Spec{} = target, %DateTime{} = now) do
    {:ok, traces} =
      Repo.with_tenant(candidate.tenant_id, fn ->
        candidate
        |> failure_rows(target, now)
        |> Enum.map(&trace(&1, target))
        |> Enum.reject(&is_nil/1)
        |> Enum.take(RunnerSpecTune.max_traces())
      end)

    {template_id, template_version} = target.prompt

    object = %{
      "target" => %{"id" => target.id, "version" => target.version},
      "template" => %{"id" => template_id, "version" => template_version},
      "eval_set" => eval_set(target),
      "window" => %{
        "since" => candidate.since && DateTime.to_iso8601(candidate.since),
        "until" => DateTime.to_iso8601(now)
      },
      "outcome_rows" => candidate.outcome_rows,
      "traces" => traces
    }

    fit(object)
  end

  defp fit(%{"traces" => []}), do: {:error, :nothing_to_learn}

  defp fit(%{"traces" => traces} = object) do
    if ByteRule.bytes(object) <= RunnerSpecTune.max_bytes(),
      do: {:ok, object},
      else: fit(%{object | "traces" => Enum.drop(traces, -1)})
  end

  defp failure_rows(candidate, target, now) do
    from(o in RunOutcome,
      where: o.tenant_id == ^candidate.tenant_id and o.project_id == ^candidate.project_id,
      where: o.spec_id == ^target.id and o.inserted_at <= ^now,
      order_by: [desc: o.inserted_at, desc: o.id],
      limit: ^@max_rows_read
    )
    |> since(candidate.since)
    |> Repo.all()
  end

  defp since(query, nil), do: query
  defp since(query, %DateTime{} = at), do: where(query, [o], o.inserted_at > ^at)

  # One trace, or nil for a row with no failure (or whose story is gone).
  defp trace(%RunOutcome{} = row, target) do
    with [_ | _] = failures <- failures(row),
         text when is_binary(text) <- story_text(row) do
      %{
        "trace_id" => row.dispatch_id,
        "failures" => failures,
        "agent_decision" => agent_decision(row),
        "human_decision" => human_decision(row, target),
        "untrusted" => fenced(text)
      }
    else
      _ -> nil
    end
  end

  @doc """
  The failure codes `row`'s signals and end reason carry, in `RunnerSpecTune.failure_codes/0`
  order. Every one is loopctl's own record of what happened to the run's work.
  """
  @spec failures(RunOutcome.t()) :: [String.t()]
  def failures(%RunOutcome{signals: signals, end_reason: end_reason}) do
    value = fn name -> get_in(signals, [name, "value"]) end
    findings = value.("review_findings")

    checks = %{
      "human_override" => value.("human_override") == true,
      "budget_exhausted" => end_reason in RunnerStages.budget_reasons(),
      "merge_gate_refused" => value.("merge_gate") == "refuse",
      "merge_refused" => value.("merge_refused") == true,
      "ci_red" => value.("ci_result") == "red",
      "review_findings_high" =>
        is_map(findings) and is_integer(findings["findings"]) and
          findings["findings"] >= SpecTunerV1.review_findings_high(),
      "draft_refused" => value.("draft_screen") == "refused"
    }

    for code <- RunnerSpecTune.failure_codes(), Map.fetch!(checks, code), do: code
  end

  # What the agent decided, as loopctl recorded it: a verdict's outcome, a draft's screen, or
  # the session's end reason. Kept only when it is a code-shaped string.
  defp agent_decision(%RunOutcome{signals: signals, end_reason: end_reason}) do
    decision =
      get_in(signals, ["verdict", "value", "outcome"]) ||
        get_in(signals, ["draft_screen", "value"]) || end_reason

    if is_binary(decision) and Regex.match?(~r/\A[a-z][a-z0-9_]{0,63}\z/, decision),
      do: %{"outcome" => decision},
      else: nil
  end

  @doc """
  The human's decision on an overridden run of `target`: the stage the human sent the story to
  (`human_route`) and the target's outcomes whose route ends there, or nil when no human
  overrode the run. A route no outcome ends at (a re-triage, `detected`) carries `[]`: the human
  asked for the run again, which names no outcome a case could expect.
  """
  @spec human_decision(RunOutcome.t(), Spec.t()) :: map() | nil
  def human_decision(%RunOutcome{signals: signals}, %Spec{} = target) do
    with true <- get_in(signals, ["human_override", "value"]) == true,
         route when is_binary(route) <- get_in(signals, ["human_route", "value"]) do
      %{"route" => route, "outcomes" => outcomes_ending_at(target, route)}
    else
      _ -> nil
    end
  end

  defp outcomes_ending_at(%Spec{outcomes: outcomes}, route) do
    outcomes
    |> Enum.filter(fn {_outcome, transitions} ->
      match?({_from, to, _edge} when is_atom(to), List.last(transitions)) and
        Atom.to_string(elem(List.last(transitions), 1)) == route
    end)
    |> Enum.map(fn {outcome, _route} -> outcome end)
    |> Enum.sort()
  end

  # The story's text from loopctl's rows: its intake record's reporter text when it has one,
  # else its own title and description. Inside the caller's tenant transaction.
  defp story_text(%RunOutcome{tenant_id: tenant_id, story_id: story_id})
       when is_binary(story_id) do
    Repo.one(
      from st in Story,
        left_join: rec in Record,
        on: rec.id == st.intake_record_id and rec.tenant_id == st.tenant_id,
        where: st.tenant_id == ^tenant_id and st.id == ^story_id,
        select: {rec.untrusted_title, rec.untrusted_body, st.title, st.description}
    )
    |> case do
      nil -> nil
      {title, body, _st_title, _st_desc} when is_binary(title) -> join([title, body])
      {nil, _body, st_title, st_desc} -> join([st_title, st_desc])
    end
  end

  defp story_text(_row), do: nil

  defp join(parts), do: parts |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join("\n\n")

  # Cut, THEN fenced; cut further until the rendered block fits.
  defp fenced(text), do: fenced(text, @untrusted_raw_chars)

  defp fenced(text, chars) do
    rendered = Untrusted.render("traced_story", String.slice(text, 0, chars))

    if String.length(rendered) <= RunnerSpecTune.max_untrusted_length() or chars <= 0,
      do: rendered,
      else: fenced(text, chars - 100)
  end

  # ── the effect ─────────────────────────────────────────────────────────────────────────────

  @doc """
  THE `:tuning_draft` EFFECT: answers the draft whose dispatch `record` just recorded a result
  on. Runs INSIDE the ledger's transaction, so it opens none of its own.

  The status is `decide/2`'s over the draft's own input and the validated result, never the
  runner's. A `proposed` draft supersedes the pair's earlier `proposed` ones. A dispatch with
  no draft, or whose draft is already answered, writes nothing. The run's outcome row gets the
  stored status as its `tuning_status` signal.
  """
  @spec write_result(DispatchRecord.t(), map()) :: :ok
  def write_result(%DispatchRecord{tenant_id: tenant_id} = record, %{} = result) do
    draft =
      Repo.one(
        from d in TuningDraft,
          where: d.tenant_id == ^tenant_id and d.dispatch_id == ^record.dispatch_id,
          where: d.status in [:pending, :abandoned],
          lock: "FOR UPDATE"
      )

    case draft do
      nil ->
        Logger.warning(
          "Tuning: result for a dispatch with no open draft, nothing stored: " <>
            "dispatch_id=#{record.dispatch_id}",
          tenant_id: tenant_id
        )

        :ok

      %TuningDraft{} = draft ->
        answer(record, draft, result)
    end
  end

  defp answer(record, draft, result) do
    {status, reasons} = decide(draft, result)
    now = DateTime.utc_now()
    scores = result.scores

    if status == :proposed, do: supersede_proposed(draft, now)

    draft
    |> Ecto.Changeset.change(
      status: status,
      rejection_reasons: Enum.map(reasons, &Atom.to_string/1),
      to_version: result.proposed_template.to_version,
      new_cases: %{"cases" => result.new_cases},
      diff: result.proposed_template.diff,
      current_score: scores.current,
      proposed_score: scores.proposed,
      per_case: %{"cases" => scores.per_case},
      answered_at: now
    )
    |> Repo.update!()

    Outcomes.put_signal_in(Repo, record, "tuning_status", Atom.to_string(status), "agent_result")
  end

  defp supersede_proposed(draft, now) do
    from(d in TuningDraft,
      where: d.tenant_id == ^draft.tenant_id and d.project_id == ^draft.project_id,
      where: d.target_spec_id == ^draft.target_spec_id and d.status == :proposed,
      where: d.id != ^draft.id
    )
    |> Repo.update_all(set: [status: :superseded, updated_at: now])
  end

  @doc """
  loopctl's verdict on a tuning result, as `{status, reasons}`: `{:proposed, []}` or
  `{:rejected, [reason, ...]}`. Pure: reads the draft's own stored input and the result
  `spec_tuner@1`'s schema validated, and trusts NONE of the runner's conclusions — the scores
  are recomputed from `per_case`, and a score that disagrees with them is itself a reason.

  Reasons, in this order:

  - `:template_mismatch` — the proposal is not a newer version of the template the draft sent;
  - `:unknown_trace` — a new case names a trace the draft did not send;
  - `:expected_not_human_decision` — a case built on a trace a human overrode does not expect
    exactly the outcomes of that human's decision;
  - `:duplicate_case` — two cases, or two per-case lines, share a name;
  - `:per_case_incomplete` — a new case has no per-case line marked new;
  - `:scores_inconsistent` — `current` or `proposed` is not the count of its per-case column;
  - `:no_existing_cases` — no existing case was scored, so no regression can be ruled out;
  - `:regression` — an existing case that passed under the current template fails under the
    proposed one, however much the total improved;
  - `:not_better` — the proposed template does not pass strictly more cases.
  """
  @spec decide(TuningDraft.t() | map(), map()) :: {:proposed | :rejected, [atom()]}
  def decide(%{input: input} = draft, %{} = result) do
    traces = Map.new(input["traces"] || [], &{&1["trace_id"], &1})

    checks =
      case_checks(result.new_cases, traces, result.scores.per_case) ++
        score_checks(result.scores)

    case for(
           {reason, true} <- [{:template_mismatch, template_mismatch?(draft, result)} | checks],
           do: reason
         ) do
      [] -> {:proposed, []}
      reasons -> {:rejected, reasons}
    end
  end

  defp template_mismatch?(draft, %{proposed_template: template}) do
    template.id != draft.template_id or template.from_version != draft.from_version or
      template.to_version <= template.from_version
  end

  # What the new cases claim about the traces loopctl sent, then whether each is scored.
  defp case_checks(cases, traces, per_case) do
    [
      unknown_trace: Enum.any?(cases, &(not Map.has_key?(traces, &1.source_trace_id))),
      expected_not_human_decision: Enum.any?(cases, &(not expects_human_decision?(&1, traces))),
      duplicate_case:
        duplicated?(Enum.map(cases, & &1.name)) or duplicated?(Enum.map(per_case, & &1.case)),
      per_case_incomplete: not every_new_case_scored?(cases, per_case)
    ]
  end

  # The verdict itself, from the per-case lines alone: the runner's totals only have to agree.
  defp score_checks(%{per_case: per_case} = scores) do
    [
      scores_inconsistent: not consistent?(scores),
      no_existing_cases: not Enum.any?(per_case, & &1.existing),
      regression: Enum.any?(per_case, &(&1.existing and &1.current and not &1.proposed)),
      not_better: count(per_case, :proposed) <= count(per_case, :current)
    ]
  end

  # A case built on a trace a human overrode must expect exactly that decision's outcomes. A
  # trace with no human decision — a budget kill, a red CI — leaves the expectation to the case.
  defp expects_human_decision?(new_case, traces) do
    case get_in(traces, [new_case.source_trace_id, "human_decision"]) do
      %{"outcomes" => [_ | _] = outcomes} ->
        Enum.sort(new_case.expectations.outcomes_allowed) == Enum.sort(outcomes)

      _no_decision ->
        true
    end
  end

  defp duplicated?(names), do: Enum.uniq(names) != names

  defp every_new_case_scored?(cases, per_case) do
    new = for line <- per_case, not line.existing, into: MapSet.new(), do: line.case
    Enum.all?(cases, &MapSet.member?(new, &1.name))
  end

  defp consistent?(%{current: current, proposed: proposed, per_case: per_case}) do
    total = length(per_case)

    current.total == total and proposed.total == total and
      current.passed == count(per_case, :current) and
      proposed.passed == count(per_case, :proposed)
  end

  defp count(per_case, column), do: Enum.count(per_case, &Map.fetch!(&1, column))

  # ── the operator's surface ─────────────────────────────────────────────────────────────────

  @doc """
  One page of `tenant_id`'s drafts, newest first. Filters: `:project_id`, `:spec_id` (the
  target), `:status` (an atom of `TuningDraft.statuses/0`). Options: `:limit` (default
  #{@default_limit}, at most #{@max_limit}) and `:cursor`, a position `decode_cursor/2`
  returned.
  """
  @spec list(Ecto.UUID.t(), keyword()) :: {:ok, page()}
  def list(tenant_id, opts \\ []) do
    limit = (Keyword.get(opts, :limit) || @default_limit) |> min(@max_limit) |> max(1)

    query =
      from(d in TuningDraft,
        where: d.tenant_id == ^tenant_id,
        order_by: [desc: d.inserted_at, desc: d.id],
        limit: ^(limit + 1)
      )
      |> filter(:project_id, Keyword.get(opts, :project_id))
      |> filter(:target_spec_id, Keyword.get(opts, :spec_id))
      |> filter(:status, Keyword.get(opts, :status))
      |> after_cursor(Keyword.get(opts, :cursor))

    {:ok, rows} = Repo.with_tenant(tenant_id, fn -> Repo.all(query) end)
    {page, rest} = Enum.split(rows, limit)

    next =
      case {rest, List.last(page)} do
        {[_ | _], %TuningDraft{} = last} -> {last.inserted_at, last.id}
        _ -> nil
      end

    {:ok, %{data: page, has_more: rest != [], next_cursor: next}}
  end

  defp filter(query, _field, nil), do: query
  defp filter(query, field, value), do: where(query, [d], field(d, ^field) == ^value)

  defp after_cursor(query, nil), do: query

  defp after_cursor(query, {%DateTime{} = at, id}) when is_binary(id),
    do: where(query, [d], d.inserted_at < ^at or (d.inserted_at == ^at and d.id < ^id))

  @doc "The opaque, tenant-bound string for a `list/2` position."
  @spec encode_cursor(Ecto.UUID.t(), KeysetCursor.position()) :: String.t()
  def encode_cursor(tenant_id, position),
    do: KeysetCursor.encode(@cursor_namespace, tenant_id, position)

  @doc "A `list/2` position from its string, or `{:error, :invalid}` for any other string."
  @spec decode_cursor(Ecto.UUID.t(), String.t()) ::
          {:ok, KeysetCursor.position()} | {:error, :invalid}
  def decode_cursor(tenant_id, cursor),
    do: KeysetCursor.decode(@cursor_namespace, tenant_id, cursor)

  @doc """
  Records that a person LANDED `draft_id`: its template change merged in the pull request at
  `pr_url` (`https://github.com/<owner>/<repo>/pull/<n>`). Only a `proposed` draft may be
  landed. This writes the draft row and an audit entry and nothing else — the template and the
  spec version are code, changed by that pull request, never by loopctl (AC-48.13.4).

  `actor` is the server-resolved caller (`%{api_key_id:, label:}`), never request data.
  `{:error, :not_found | :not_proposed | :invalid_pr_url}` otherwise.
  """
  @spec mark_landed(Ecto.UUID.t(), Ecto.UUID.t(), term(), map()) ::
          {:ok, TuningDraft.t()} | {:error, :not_found | :not_proposed | :invalid_pr_url}
  def mark_landed(tenant_id, draft_id, pr_url, %{} = actor) do
    with :ok <- valid_pr_url(pr_url),
         {:ok, {:ok, draft}} <-
           Repo.with_tenant(tenant_id, fn -> land(tenant_id, draft_id, pr_url) end) do
      audit_landed(tenant_id, draft, actor)
      {:ok, draft}
    else
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp valid_pr_url(url) when is_binary(url) do
    if byte_size(url) <= 500 and Regex.match?(pr_url_format(), url),
      do: :ok,
      else: {:error, :invalid_pr_url}
  end

  defp valid_pr_url(_url), do: {:error, :invalid_pr_url}

  defp land(tenant_id, draft_id, pr_url) do
    draft =
      with {:ok, id} <- Ecto.UUID.cast(draft_id) do
        Repo.one(
          from d in TuningDraft,
            where: d.tenant_id == ^tenant_id and d.id == ^id,
            lock: "FOR UPDATE"
        )
      end

    case draft do
      %TuningDraft{status: :proposed} = draft ->
        draft
        |> Ecto.Changeset.change(status: :landed, pr_url: pr_url, landed_at: DateTime.utc_now())
        |> Repo.update()

      %TuningDraft{} ->
        {:error, :not_proposed}

      _none ->
        {:error, :not_found}
    end
  end

  defp audit_landed(tenant_id, draft, actor) do
    tenant_id
    |> Audit.create_log_entry(%{
      entity_type: "spec_tuning_draft",
      entity_id: draft.id,
      action: "tuning_draft_landed",
      actor_type: "api_key",
      actor_id: Map.get(actor, :api_key_id),
      actor_label: Map.get(actor, :label),
      metadata: %{
        "target_spec_id" => draft.target_spec_id,
        "template_id" => draft.template_id,
        "from_version" => draft.from_version,
        "to_version" => draft.to_version,
        "pr_url" => draft.pr_url
      }
    })
    |> case do
      {:ok, _entry} ->
        :ok

      {:error, reason} ->
        Logger.error(
          "Tuning: landed draft's audit entry failed: draft_id=#{draft.id} " <>
            "reason=#{inspect(reason)}",
          tenant_id: tenant_id
        )
    end
  end
end
