defmodule Loopctl.Agents.Outcomes do
  @moduledoc """
  The run-outcome ledger (Epic 48, US-48.12): one `agent_run_outcomes` row per runner
  dispatch, keyed by the agent spec `{id, version}` it ran under, with what later happened to
  its work appended as signals. An agent's track record is then a query (`summary/3`), and the
  improvement loop (US-48.13) learns from what humans and gates did with the output rather
  than from the agent's own report.

  ## Every write rides a write that already exists, in its transaction

  No runner message is new and no transaction is new. Each function here takes the `repo` of
  the transaction its caller is already in and writes inside it, so the event and its outcome
  commit together or not at all:

  | written by | in the transaction of | what |
  |---|---|---|
  | `Loopctl.Runners.DispatchLedger` (`session_ended`) | the ledger row's session-end write | the row, `end_reason` = the runner's reason |
  | `Loopctl.Delivery.TriageVerdict` | the `triage_verdicts` insert | the row, `end_reason` `triage_verdict`/`triage_incomplete`, signal `verdict` |
  | `Loopctl.Runners.DispatchLedger` (`agent_result`) | the ledger row's result write and its effect | the row, `end_reason` `agent_result`, signal `draft_screen` |
  | `Loopctl.Delivery.Stages` (every transition and effect) | the stage row's compare-and-set | `merge_gate`, `ci_result`, `merged`, `merge_refused`, `human_override`, `requeued_after_budget_kill` |
  | `Loopctl.Progress.record_review/4` | the review record's Multi | `review_findings` |

  ## Idempotent by `(dispatch_id, signal)`

  The row is unique on `(tenant_id, dispatch_id)`. Its end is written once (`ended_at IS
  NULL` guards the upsert), and each signal once (`jsonb_exists` guards the append), so a
  redelivered session end or a repeated gate event leaves the row as it was. A signal that
  arrives BEFORE the session ends — a build session's merge gate and merge come while it is
  still running — creates the row from the ledger's identity, and the session end fills the
  end columns in later.

  ## Which dispatch a story-level signal belongs to

  A stage transition, a gate decision or a review names a STORY, not a dispatch. It is
  credited to the story's latest ACCEPTED claim-holding (`:build`) dispatch — the session whose
  work it is. A story re-queued and dispatched again credits the new session from then on.

  ## Never session text

  Every value is loopctl's own: an enum, a stage, a boolean, a count, an id. `source` names
  the event (`"stage:ci->merged:forward"`, `"effect:merge_gate_allowed_sha"`,
  `"review_record:<id>"`, `"triage_verdict"`, `"agent_result"`).

  ## Turns, from the session end

  `turns` is the runner's own count from its `session_ended` report (runner contract 1.27.0,
  `turns_used`), which the ledger stores on the dispatch's row with the report
  (`session_turns_used`); the session-end write copies it here in the same transaction. It is
  NULL for a session whose end did not report one — a 1.26.0 runner, or a session that ended
  through a result message (`triage_verdict`, `agent_result`), which carries no count.

  ## Not recorded, because no event carries it

  `cost_millicents` stays NULL: no runner message reports it. Review findings are counts only —
  `review_records` holds no severity. A `:draft`'s release, edit or discard has no event:
  loopctl never sends a reply draft and records nothing a person does with it.
  """

  import Ecto.Query

  require Logger

  alias Loopctl.Agents.Registry
  alias Loopctl.Agents.RunOutcome
  alias Loopctl.Agents.Spec
  alias Loopctl.Delivery.Escalations
  alias Loopctl.Delivery.RunnerStages
  alias Loopctl.Delivery.StoryStage
  alias Loopctl.ReplyDrafts.ReplyDraft
  alias Loopctl.Repo
  alias Loopctl.Runners.DispatchLedger
  alias Loopctl.Runners.DispatchRecord
  alias Loopctl.WorkBreakdown.Story

  @default_window_days 30
  @max_window_days 365

  @typedoc "A repo a caller's transaction runs on."
  @type repo :: module()

  @typedoc "One spec version's line of `summary/3`."
  @type version_summary :: %{
          spec_version: pos_integer(),
          runs: non_neg_integer(),
          ended: non_neg_integer(),
          successes: non_neg_integer(),
          human_overrides: non_neg_integer(),
          budget_exhausted: non_neg_integer(),
          success_rate: float(),
          human_override_rate: float(),
          budget_exhausted_rate: float(),
          median_elapsed_s: float() | nil,
          median_turns: float() | nil
        }

  @typedoc "What `summary/3` returns."
  @type summary :: %{
          spec_id: String.t(),
          window_days: pos_integer(),
          since: DateTime.t(),
          until: DateTime.t(),
          versions: [version_summary()]
        }

  @doc "The summary window when none is given, in days."
  @spec default_window_days() :: pos_integer()
  def default_window_days, do: @default_window_days

  @doc "The longest summary window, in days."
  @spec max_window_days() :: pos_integer()
  def max_window_days, do: @max_window_days

  # ── writers ────────────────────────────────────────────────────────────────────────────────

  @doc """
  Records the END of `record`'s session on its outcome row, inside the caller's transaction
  on `repo`: creates the row if no signal has yet, and fills `ended_at`, `elapsed_s`,
  `end_reason` and `turns` (the ledger row's `session_turns_used`, NULL when the session end
  reported none) ONCE — a row already ended is left exactly as it is.

  `end_reason` is loopctl's own enum: the runner's `session_ended` reason, or the result
  message that ended the session. Options: `:now` (the clock, `DateTime.utc_now/0` by
  default).
  """
  @spec record_end_in(repo(), DispatchRecord.t(), String.t(), keyword()) :: :ok
  def record_end_in(repo, %DispatchRecord{} = record, end_reason, opts \\ [])
      when is_binary(end_reason) do
    now = now(opts)

    with {:ok, identity} <- identity(repo, record) do
      elapsed = elapsed_s(identity.started_at, now)
      turns = record.session_turns_used

      upsert =
        from(o in RunOutcome,
          where: is_nil(o.ended_at),
          update: [
            set: [
              ended_at: ^now,
              elapsed_s: ^elapsed,
              end_reason: ^end_reason,
              turns: ^turns,
              updated_at: ^now
            ]
          ]
        )

      row =
        identity
        |> Map.merge(%{ended_at: now, elapsed_s: elapsed, end_reason: end_reason, turns: turns})
        |> stamp(now)

      repo.insert_all(RunOutcome, [row],
        on_conflict: upsert,
        conflict_target: [:tenant_id, :dispatch_id]
      )
    end

    :ok
  end

  @doc """
  `record_end_in/4` for a dispatch named by id — read from the ledger inside the caller's
  transaction on `repo` — followed by `signals`, each `{name, value, source}` appended once.
  For a result message whose writer holds the dispatch id but not its ledger row
  (`Loopctl.Delivery.TriageVerdict`). A dispatch the ledger no longer holds records nothing.
  """
  @spec record_result_in(
          repo(),
          Ecto.UUID.t(),
          Ecto.UUID.t(),
          String.t(),
          [{String.t(), term(), String.t()}],
          keyword()
        ) :: :ok
  def record_result_in(repo, tenant_id, dispatch_id, end_reason, signals, opts \\ []) do
    record =
      repo.one(
        from r in DispatchRecord,
          where: r.tenant_id == ^tenant_id and r.dispatch_id == ^dispatch_id
      )

    with %DispatchRecord{} <- record do
      opts = Keyword.put_new_lazy(opts, :now, &DateTime.utc_now/0)
      :ok = record_end_in(repo, record, end_reason, opts)

      Enum.each(signals, fn {name, value, source} ->
        :ok = put_signal_in(repo, record, name, value, source, opts)
      end)
    end

    :ok
  end

  @doc """
  Appends `signal` to `record`'s outcome row ONCE, inside the caller's transaction on `repo`,
  creating the row from the ledger's identity if it does not exist yet. A signal already on
  the row is left as it is, whatever value this call carries.

  `value` must be JSON-encodable and loopctl's own (an enum, a boolean, a count, a map of
  them); `source` names the system event that proves it.
  """
  @spec put_signal_in(repo(), DispatchRecord.t(), String.t(), term(), String.t(), keyword()) ::
          :ok
  def put_signal_in(repo, %DispatchRecord{} = record, signal, value, source, opts \\ [])
      when is_binary(signal) and is_binary(source) do
    now = now(opts)

    with {:ok, identity} <- identity(repo, record) do
      repo.insert_all(RunOutcome, [stamp(identity, now)],
        on_conflict: :nothing,
        conflict_target: [:tenant_id, :dispatch_id]
      )

      append(repo, record.tenant_id, record.dispatch_id, signal, value, source, now)
    end

    :ok
  end

  @doc """
  The stage machine's hook: called by `Loopctl.Delivery.Stages` inside every transition's own
  transaction, with the row's pre-image (`previous`), the row after the transition and the
  transition. Records the build and judge signals the transition proves; every other
  transition writes nothing. `previous` is nil only for a row's first write, which no
  resolution can be, so a nil pre-image never reaches the resolution clause's read of it.
  """
  @spec observe_transition(
          repo(),
          StoryStage.t() | nil,
          StoryStage.t(),
          {atom(), atom(), atom()},
          keyword()
        ) :: :ok
  def observe_transition(repo, previous, row, transition, opts \\ [])

  def observe_transition(repo, _previous, row, {:ci, :escalated, :merge_gate} = t, opts),
    do: build_signal(repo, row, "merge_gate", "refuse", source(t), opts)

  def observe_transition(repo, _previous, row, {:ci, :implementing, :ci_red} = t, opts),
    do: build_signal(repo, row, "ci_result", "red", source(t), opts)

  def observe_transition(repo, _previous, row, {from, :merged, _edge} = t, opts) do
    # First write wins: a CI result already recorded red stays red, so `ci_result` reads as
    # "what CI said the first time this session's work met it".
    if from == :ci, do: build_signal(repo, row, "ci_result", "green", source(t), opts)
    build_signal(repo, row, "merged", true, source(t), opts)
  end

  def observe_transition(repo, _previous, row, {:merged, _to, :merge_refused} = t, opts),
    do: build_signal(repo, row, "merge_refused", true, source(t), opts)

  def observe_transition(
        repo,
        %StoryStage{} = previous,
        row,
        {:escalated, to, :human_resolution} = t,
        opts
      ) do
    if implementer_touched?(previous),
      do: budget_requeue(repo, row, to, source(t), opts),
      else: triage_override(repo, previous, to, source(t), opts)
  end

  def observe_transition(_repo, _previous, _row, _transition, _opts), do: :ok

  @doc """
  The stage machine's effect hook: called by `Loopctl.Delivery.Stages` inside the write that
  records an identity on the stage row. `merge_gate_allowed_sha` is the merge gate's ALLOW
  (`Loopctl.Delivery.MergePrecondition`); every other effect writes nothing.
  """
  @spec observe_effect(repo(), StoryStage.t(), atom(), keyword()) :: :ok
  def observe_effect(repo, row, effect, opts \\ [])

  def observe_effect(repo, %StoryStage{} = row, :merge_gate_allowed_sha, opts),
    do: build_signal(repo, row, "merge_gate", "allow", "effect:merge_gate_allowed_sha", opts)

  def observe_effect(_repo, _row, _effect, _opts), do: :ok

  @doc """
  Records a review of `story_id` on its build dispatch's row as `review_findings` — the
  record's own counts (`findings`, `fixes`, `disproved`) — inside the review record's
  transaction on `repo`. The first review recorded for the dispatch is the one kept.
  `review_records` holds no severity, so none is recorded.
  """
  @spec observe_review(repo(), Ecto.UUID.t(), Ecto.UUID.t(), map(), keyword()) :: :ok
  def observe_review(repo, tenant_id, story_id, review, opts \\ []) do
    case latest_build_dispatch(repo, tenant_id, story_id) do
      nil ->
        :ok

      record ->
        value = %{
          "findings" => review.findings_count,
          "fixes" => review.fixes_count,
          "disproved" => review.disproved_count,
          "review_record_id" => review.id
        }

        put_signal_in(repo, record, "review_findings", value, "review_record:#{review.id}", opts)
    end
  end

  @doc """
  Records what a `:draft` dispatch's effect stored — the `reply_drafts` row's `status`,
  `drafted` or `refused` — as `draft_screen`, inside the ledger's own transaction on `repo`.
  Read from the row the effect just wrote, so the signal is the stored fact rather than what
  the screen predicted. A dispatch whose effect stored nothing records nothing.
  """
  @spec observe_reply_draft(repo(), DispatchRecord.t(), keyword()) :: :ok
  def observe_reply_draft(repo, %DispatchRecord{} = record, opts \\ []) do
    status =
      repo.one(
        from d in ReplyDraft,
          where: d.tenant_id == ^record.tenant_id and d.dispatch_id == ^record.dispatch_id,
          select: d.status
      )

    case status do
      nil ->
        :ok

      status ->
        put_signal_in(repo, record, "draft_screen", Atom.to_string(status), "agent_result", opts)
    end
  end

  # ── reader ─────────────────────────────────────────────────────────────────────────────────

  @doc """
  Per-version counts and rates for `spec_id` in `tenant_id`, over the rows FIRST RECORDED in
  the window ending at `:now` (default `DateTime.utc_now/0`) and `:window_days` long (default
  #{@default_window_days}, at most #{@max_window_days}). Newest version first; a spec with no
  rows in the window has `versions: []`.

  Per version: `runs`, `ended` (rows whose session end was recorded), and

  - `successes` — a `:build` row whose work merged; a `:judge` row that recorded a verdict a
    human did not override; a `:draft` row whose draft was stored `drafted`;
  - `human_overrides` — rows carrying `human_override: true`;
  - `budget_exhausted` — rows whose session ended `wall_clock_exceeded` or
    `max_turns_exceeded`;

  each also as a rate over `runs`, and the median `elapsed_s` and `turns` over the rows that
  carry one (`nil` when none does — `turns` only from a runner on contract 1.27.0 or later).

  A bounded aggregate over one spec's rows in one tenant, on `(tenant_id, spec_id,
  inserted_at)`: an ordinary tenant read on `Loopctl.Repo`, not a `Loopctl.HeavyRead` one.
  """
  @spec summary(Ecto.UUID.t(), String.t(), keyword()) ::
          {:ok, summary()} | {:error, :invalid_window}
  def summary(tenant_id, spec_id, opts \\ []) when is_binary(tenant_id) and is_binary(spec_id) do
    until = now(opts)
    days = Keyword.get(opts, :window_days, @default_window_days)

    if is_integer(days) and days in 1..@max_window_days do
      since = DateTime.add(until, -days * 86_400, :second)

      {:ok, versions} =
        Repo.with_tenant(tenant_id, fn ->
          tenant_id |> summary_query(spec_id, since, until) |> Repo.all()
        end)

      {:ok,
       %{
         spec_id: spec_id,
         window_days: days,
         since: since,
         until: until,
         versions: Enum.map(versions, &rates/1)
       }}
    else
      {:error, :invalid_window}
    end
  end

  defp summary_query(tenant_id, spec_id, since, until) do
    budget = RunnerStages.budget_reasons()

    per_row =
      from o in RunOutcome,
        where: o.tenant_id == ^tenant_id and o.spec_id == ^spec_id,
        where: o.inserted_at >= ^since and o.inserted_at <= ^until,
        select: %{
          version: o.spec_version,
          ended?: not is_nil(o.ended_at),
          elapsed_s: o.elapsed_s,
          turns: o.turns,
          budget?: o.end_reason in ^budget,
          override?:
            fragment("coalesce((?->'human_override'->>'value')::boolean, false)", o.signals),
          success?:
            fragment(
              """
              CASE ?
                WHEN 'build' THEN coalesce((?->'merged'->>'value')::boolean, false)
                WHEN 'judge' THEN coalesce(? = 'triage_verdict', false)
                  AND NOT coalesce((?->'human_override'->>'value')::boolean, false)
                WHEN 'draft' THEN coalesce(?->'draft_screen'->>'value' = 'drafted', false)
                ELSE false
              END
              """,
              o.archetype,
              o.signals,
              o.end_reason,
              o.signals,
              o.signals
            )
        }

    from r in subquery(per_row),
      group_by: r.version,
      order_by: [desc: r.version],
      select: %{
        spec_version: r.version,
        runs: count(),
        ended: filter(count(), r.ended?),
        successes: filter(count(), r.success?),
        human_overrides: filter(count(), r.override?),
        budget_exhausted: filter(count(), r.budget?),
        median_elapsed_s: fragment("percentile_cont(0.5) WITHIN GROUP (ORDER BY ?)", r.elapsed_s),
        median_turns: fragment("percentile_cont(0.5) WITHIN GROUP (ORDER BY ?)", r.turns)
      }
  end

  defp rates(%{runs: runs} = line) do
    Map.merge(line, %{
      success_rate: rate(line.successes, runs),
      human_override_rate: rate(line.human_overrides, runs),
      budget_exhausted_rate: rate(line.budget_exhausted, runs),
      median_elapsed_s: float_or_nil(line.median_elapsed_s),
      median_turns: float_or_nil(line.median_turns)
    })
  end

  defp rate(_count, 0), do: 0.0
  defp rate(count, runs), do: Float.round(count / runs, 4)

  defp float_or_nil(nil), do: nil
  defp float_or_nil(value) when is_float(value), do: value
  defp float_or_nil(value) when is_integer(value), do: value / 1
  defp float_or_nil(%Decimal{} = value), do: Decimal.to_float(value)

  # ── signals from the stage machine ─────────────────────────────────────────────────────────

  defp source({from, to, edge}), do: "stage:#{from}->#{to}:#{edge}"

  defp build_signal(repo, %StoryStage{} = row, signal, value, source, opts) do
    case latest_build_dispatch(repo, row.tenant_id, row.story_id) do
      nil -> :ok
      record -> put_signal_in(repo, record, signal, value, source, opts)
    end
  end

  # A row holding any implementation identity was worked by an implementer: its escalation is
  # the implement session's, never triage's. The set is `Escalations`' own, the one re-triage
  # is refused on.
  defp implementer_touched?(%StoryStage{} = row),
    do: Enum.any?(Escalations.implementation_identities(), &(Map.fetch!(row, &1) != nil))

  # A human's resolution of a story a budget kill escalated: re-queued (`queued`) or not.
  # Recorded only when the story's latest build session DID end on a budget kill — another
  # escalation of a worked story says nothing about one.
  defp budget_requeue(repo, row, to, source, opts) do
    case latest_build_dispatch(repo, row.tenant_id, row.story_id) do
      %DispatchRecord{session_ended_reason: reason} = record when is_binary(reason) ->
        if reason in RunnerStages.budget_reasons(),
          do:
            put_signal_in(repo, record, "requeued_after_budget_kill", to == :queued, source, opts),
          else: :ok

      _none ->
        :ok
    end
  end

  # A human's resolution of a story triage escalated, judged against the VERDICT's own
  # destination (the `verdict` signal): a re-triage (`detected`) always overrides it, and any
  # other target overrides it when it is not where the verdict sent the story. A verdict whose
  # outcome row predates this ledger has no `verdict` signal and records nothing.
  defp triage_override(repo, %StoryStage{triage_dispatch_id: dispatch_id} = row, to, source, opts)
       when is_binary(dispatch_id) do
    signals =
      repo.one(
        from o in RunOutcome,
          where: o.tenant_id == ^row.tenant_id and o.dispatch_id == ^dispatch_id,
          select: o.signals
      )

    case signals do
      %{"verdict" => %{"value" => %{"destination" => destination}}} ->
        overridden? = to == :detected or Atom.to_string(to) != destination

        append(repo, row.tenant_id, dispatch_id, "human_override", overridden?, source, now(opts))

      _no_verdict ->
        :ok
    end
  end

  defp triage_override(_repo, _row, _to, _source, _opts), do: :ok

  # The story's latest ACCEPTED (or since superseded) claim-holding dispatch. Explicit tenant
  # predicate: the caller may be on `AdminRepo`, where RLS does nothing.
  defp latest_build_dispatch(repo, tenant_id, story_id) do
    from(r in DispatchRecord,
      where: r.tenant_id == ^tenant_id and r.story_id == ^story_id,
      where: r.status in ["accepted", "superseded"] and not is_nil(r.replied_at),
      order_by: [desc: r.replied_at, desc: r.inserted_at],
      limit: 1
    )
    |> DispatchLedger.where_holds_claim()
    |> repo.one()
  end

  # ── storage ────────────────────────────────────────────────────────────────────────────────

  # Once per `(dispatch_id, signal)`: an append whose signal is already on the row matches no
  # row. Two concurrent first appends serialise on the row lock, and the second re-checks the
  # WHERE against the first's committed row and writes nothing.
  defp append(repo, tenant_id, dispatch_id, signal, value, source, now) do
    entry = %{"value" => value, "at" => DateTime.to_iso8601(now), "source" => source}

    from(o in RunOutcome,
      where: o.tenant_id == ^tenant_id and o.dispatch_id == ^dispatch_id,
      where: not fragment("jsonb_exists(?, ?)", o.signals, ^signal),
      update: [
        set: [
          signals:
            fragment(
              "? || jsonb_build_object(?::text, ?)",
              o.signals,
              ^signal,
              type(^entry, :map)
            ),
          updated_at: ^now
        ]
      ]
    )
    |> repo.update_all([])

    :ok
  end

  # Everything the row says about who ran, under which spec — loopctl's own values: the ledger
  # row, the spec the registry holds for its kind (or the one its `agent_result` named), the
  # story's project. A kind no spec describes is logged and records nothing: the existing write
  # it rides must never fail on this ledger's account.
  defp identity(repo, %DispatchRecord{} = record) do
    case spec_of(record) do
      {:ok, %Spec{} = spec} ->
        {template_id, template_version} = spec.prompt

        {:ok,
         %{
           tenant_id: record.tenant_id,
           dispatch_id: record.dispatch_id,
           runner_id: record.runner_id,
           story_id: record.story_id,
           project_id: project_id(repo, record.tenant_id, record.story_id),
           kind: spec.kind,
           spec_id: spec.id,
           spec_version: spec.version,
           archetype: Atom.to_string(spec.archetype),
           prompt_template_id: template_id,
           prompt_template_version: template_version,
           started_at: record.replied_at || record.pushed_at || record.inserted_at
         }}

      {:error, reason} ->
        Logger.warning(
          "agent run outcome not recorded: no spec for dispatch_id=#{record.dispatch_id} " <>
            "kind=#{inspect(record.kind)} (#{reason})",
          tenant_id: record.tenant_id
        )

        {:error, reason}
    end
  end

  defp spec_of(%DispatchRecord{agent_result_spec: label}) when is_binary(label) do
    with [id, version] <- String.split(label, "@", parts: 2),
         {version, ""} <- Integer.parse(version) do
      Registry.fetch(id, version)
    else
      _malformed -> {:error, :unknown_spec}
    end
  end

  defp spec_of(%DispatchRecord{kind: kind}),
    do: Registry.for_kind(kind || Registry.default_kind())

  defp project_id(repo, tenant_id, story_id) do
    repo.one(
      from s in Story,
        where: s.tenant_id == ^tenant_id and s.id == ^story_id,
        select: s.project_id
    )
  end

  defp stamp(row, now),
    do:
      Map.merge(row, %{id: Ecto.UUID.generate(), signals: %{}, inserted_at: now, updated_at: now})

  defp elapsed_s(nil, _now), do: nil
  defp elapsed_s(%DateTime{} = started_at, now), do: max(DateTime.diff(now, started_at), 0)

  defp now(opts), do: Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
end
