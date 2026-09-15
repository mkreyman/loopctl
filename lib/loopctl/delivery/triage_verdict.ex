defmodule Loopctl.Delivery.TriageVerdict do
  @moduledoc """
  What a triage session's verdict MEANS to the delivery stage machine (issue #803, design §4).

  `Loopctl.ApiSpec.RunnerContract.RunnerTriageVerdict` declares the verdict's SHAPE and
  `cast_triage_verdict/1` admits or refuses one. Until this module there was no caller of
  either: the wire format shipped in contract 1.7.0 with nothing on the receiving side, the
  same way the runner's own prompt shipped before anything dispatched it.

  This is the half that decides what a verdict DOES.

  ## Control decides the transition, not the runner — and that is forced

  A runner cannot report its way to an escalation here. `:triage_escalate` is deliberately
  absent from `StageMachine.runner_reportable_edges/0`, which calls it "a control-side verdict
  about a specific gate", so a `stage` message can never carry it. That is why a verdict is
  its own message rather than a `stage` report: the runner supplies its JUDGEMENT, and the
  transition is control's conclusion from it.

  Reading it the other way — letting a session report `triaged -> escalated` directly — would
  hand the principal that read the reporter's text the ability to name its own gate outcome,
  which is the separation the whole machine is built on.

  ## Every verdict passes through `triaged` first

  `triage_for/1` returns the transitions IN ORDER, and every outcome begins with
  `{:detected, :triaged, :forward}` — triage HAPPENED, whatever it concluded. Only then does
  the outcome route:

  | `outcome` | transitions | what the reporter is told |
  |---|---|---|
  | `story` | `detected -> triaged`, `triaged -> queued` | nothing yet; the story goes on to be built |
  | `escalate` | `detected -> triaged`, `triaged -> escalated` | nothing — a human is now looking |
  | `reject` | `detected -> triaged`, `triaged -> failed` | no change was needed, and why (`:not_actionable`) |

  The intermediate `triaged` is not bookkeeping. `StageMachine.resolution_verdict/1` reads the
  whole transition rather than the destination, and `{:triaged, :failed, :triage_reject}` is
  what earns `:not_actionable` — reaching `failed` from anywhere else (a budget exhaustion,
  say) tells the reporter nothing. A verdict that jumped straight to `failed` would lose the
  one edge that distinguishes "we looked and no change was needed" from "this died".

  ## An ACCEPTED verdict writes the drafted story and QUEUES it

  `story` is the outcome that continues the loop, and until it took `{:triaged, :queued}` the
  loop had no continuation at all: `Loopctl.Delivery.DispatchDriver` selects stage rows at
  `queued`, nothing else in `lib/` writes that edge, and an accepted story therefore stopped
  at `triaged` where no production code could reach it. The table below said "the story goes
  on to be built" and nothing built it.

  Two writes, in this order, and the order is the recoverable one:

  1. the drafted `title`, `description` and `acceptance_criteria` replace the STUB row
     `Loopctl.Delivery.TriageTrigger` created — that module says so itself ("triage replaces
     this with the drafted title"), because its own title is loopctl's facts alone (a repo and
     an issue number) and an implementer needs the story;
  2. `triaged -> queued`.

  A draft written with no queue advance is a story a later resend still queues. A queue
  advance with no draft is a story a runner picks up carrying a stub title and no acceptance
  criteria — work dispatched against nothing. So the draft goes first.

  ## The verdict is UNTRUSTED and this module does not change that

  It was composed by a session whose whole job was to read attacker-controllable text, so
  every string in it is potentially shaped by that text — `story` included, whose fields
  become a story row. Nothing here executes it or puts it in a prompt. What this module reads
  is `outcome` alone, which `cast_triage_verdict/1` has already constrained to an enum, so no
  reporter-shaped string reaches a decision. The drafted `story` fields are written by the
  caller, fenced, and are not this module's business.
  """

  import Ecto.Query

  alias Loopctl.Audit
  alias Loopctl.Delivery.StageMachine
  alias Loopctl.Delivery.Stages
  alias Loopctl.Delivery.TriageVerdictRecord
  alias Loopctl.Delivery.Untrusted
  alias Loopctl.Repo
  alias Loopctl.Runners.DispatchLedger
  alias Loopctl.WorkBreakdown.Story

  @type outcome :: String.t()
  @type transition :: {StageMachine.stage(), StageMachine.stage(), StageMachine.edge()}

  # THE TRIAGE STEP ITSELF, taken by every outcome. See the moduledoc for why the
  # intermediate `triaged` is load-bearing rather than bookkeeping.
  @triaged {:detected, :triaged, :forward}

  # Attribution for the drafted-story write. Not the runner's own label: the runner supplied a
  # judgement, and writing it into the row is control's act, exactly as the transition is.
  @draft_actor "control:triage_draft"

  @routes %{
    "story" => [{:triaged, :queued, :forward}],
    "escalate" => [{:triaged, :escalated, :triage_escalate}],
    "reject" => [{:triaged, :failed, :triage_reject}]
  }

  @doc """
  The transitions a verdict implies, in order, or `{:error, {:unknown_outcome, outcome}}`.

  PURE. Takes the outcome string a cast verdict carries — never the verdict map — because
  everything else in that map is reporter-shaped and has no part in this decision.

  An unknown outcome is an ERROR rather than an empty list. `cast_triage_verdict/1` already
  constrains the enum, so reaching this clause means the contract and this table disagree,
  and the safe reading of a verdict loopctl cannot interpret is not "do nothing" — a story
  silently left at `detected` is retried by the trigger worker for ever against a condition
  nothing reports.
  """
  @spec transitions_for(outcome()) :: {:ok, [transition()]} | {:error, {:unknown_outcome, term()}}
  def transitions_for(outcome) when is_binary(outcome) do
    case Map.fetch(@routes, outcome) do
      {:ok, rest} -> {:ok, [@triaged | rest]}
      :error -> {:error, {:unknown_outcome, outcome}}
    end
  end

  def transitions_for(outcome), do: {:error, {:unknown_outcome, outcome}}

  @doc """
  Every outcome this module routes, which must be exactly the contract's enum.

  Public so the drift between the two is a TEST rather than a comment: an outcome added to
  `RunnerTriageVerdict` and forgotten here would cast successfully and then fail to route,
  which is the shape where the wire says yes and the machine says nothing.
  """
  @spec outcomes() :: [String.t()]
  def outcomes, do: @routes |> Map.keys() |> Enum.sort()

  @doc """
  True when the verdict's outcome ends the story rather than passing it on.

  `escalate` and `reject` both terminate this loop's automatic handling; `story` is the only
  one that continues. Named rather than derived at each call site because "did triage finish
  the work" is asked in more than one place and inverting it by hand is how the two drift.

  READ OFF THE DESTINATION, not off the number of transitions. It used to be
  `length(transitions) > 1`, which was true of exactly the two terminal outcomes while `story`
  took one transition — a proxy that inverted the day `story` gained its second, and it did:
  an accepted verdict now also takes `triaged -> queued`, and this said the loop had finished
  with the story it had just queued. The stage machine names the terminal stages; ask it.
  """
  @spec terminal?(outcome()) :: boolean()
  def terminal?(outcome) do
    case transitions_for(outcome) do
      {:ok, [_ | _] = transitions} ->
        {_from, to, _edge} = List.last(transitions)
        to in StageMachine.terminal_stages()

      _no_transitions_or_unknown ->
        false
    end
  end

  @type error ::
          :unknown_dispatch
          | :dispatch_not_accepted
          | :stale_claim_epoch
          | :already_recorded
          | :unknown_story_stage
          | :stale_stage
          | :audit_chain_append_failed
          | {:invalid, [String.t()]}

  @doc """
  Applies a `triage_verdict` MESSAGE already cast by
  `RunnerContract.cast_triage_verdict_message/1`, as `runner_id` in `tenant_id`.

  Returns `{:ok, %{record: record, replayed?: boolean}}`. `replayed?` is true when this exact
  verdict had already been recorded — the resend case, which is a success and applies nothing
  a second time.

  ## Recording and transitioning are ONE transaction

  Neither order works on its own and the failure is asymmetric, which is why they are atomic
  rather than sequenced. Record first and let the transition fail, and a resend finds the row,
  concludes it is a replay, and returns ok — leaving the story at `detected` for ever with
  every resend reporting success. Transition first and let the recording fail, and the resend
  is refused `stale_stage` because the row already moved, so the verdict can never be
  recorded at all. In one transaction a failure rolls back both and the resend retries the
  whole thing, which is exactly what the runner is told to do.

  ## The escalation reason never carries the session's own words

  Entering `escalated` requires a reason, and the obvious one — the verdict's
  `escalation_reasons`, which say why the session wants a human — is composed by a principal
  that had just read attacker-controllable reporter text. That string would land in the
  hash-chained audit log, which is append-only and cannot be corrected. So the reason is
  built from the ENUMS (`triage_verdict:escalate`, `triage_verdict:<incomplete_reason>`), both
  of which the cast already constrained, and the session's own prose stays in the verdict
  record where an operator reads it as data.
  """
  @spec apply(Ecto.UUID.t(), Ecto.UUID.t(), map()) ::
          {:ok, %{record: TriageVerdictRecord.t(), replayed?: boolean()}} | {:error, error()}
  def apply(tenant_id, runner_id, %{} = message) do
    with {:ok, session} <-
           DispatchLedger.accepted_session(tenant_id, runner_id, message.dispatch_id),
         :ok <- epoch_matches(session, message),
         {:ok, transitions} <- route(message) do
      record_and_advance(tenant_id, runner_id, session, message, transitions)
    end
  end

  # The dispatch's own epoch, checked before a transaction is opened, exactly as
  # `Loopctl.Delivery.RunnerStages` checks it. The FENCE is the story's epoch read under a
  # lock inside `Stages.advance/4`; this refuses a message that does not even match the
  # dispatch it names, for the cost of a read the caller already made.
  defp epoch_matches(%{claim_epoch: epoch}, %{claim_epoch: epoch}), do: :ok
  defp epoch_matches(_session, _message), do: {:error, :stale_claim_epoch}

  defp route(%{incomplete: reason}) when is_binary(reason) do
    # EVERY incomplete reason escalates. A triage run that produced nothing usable needs a
    # human, which is what `escalate` means; the enum exists so an operator can tell a crash
    # from a refused verdict, not so they route differently.
    {:ok, [@triaged, {:triaged, :escalated, :triage_escalate}]}
  end

  defp route(%{verdict: %{outcome: outcome}}), do: transitions_for(outcome)
  defp route(_message), do: {:error, {:invalid, ["exactly_one_of_verdict_or_incomplete"]}}

  defp record_and_advance(tenant_id, runner_id, session, message, transitions) do
    digest = TriageVerdictRecord.digest(message)

    # INSIDE `with_tenant/2`, because `triage_verdicts` is RLS-scoped and a read with no
    # tenant context matches NOTHING under the `Loopctl.Repo` role — `current_tenant_id()` is
    # NULL and the policy excludes every row. Bare, this read always answered `nil` in
    # production, so the replay branch could never be taken: every byte-identical resend fell
    # through to the insert, tripped the unique index and was refused `already_recorded`, and
    # the feature's central guarantee inverted into a permanent refusal. Invisible in tests,
    # where the sandbox connection owns the table and no policy applies.
    case in_tenant(tenant_id, fn -> existing(tenant_id, message.dispatch_id) end) do
      %TriageVerdictRecord{payload_digest: ^digest} = record ->
        replay(tenant_id, runner_id, session, message, transitions, record)

      %TriageVerdictRecord{} ->
        {:error, :already_recorded}

      nil ->
        fresh(tenant_id, runner_id, session, message, digest, transitions)
    end
  end

  # THE RESEND, and it RE-ATTEMPTS rather than trusting the record. See the moduledoc: the
  # record and the transitions are not atomic, so a record whose transitions did not land is
  # a real state, and answering ok to it would strand the story at `detected` while every
  # resend reported success.
  #
  # `stale_stage` on the first transition is the ordinary case — the story is already past
  # `detected`, so the work was done — and is a replay rather than a refusal.
  defp replay(tenant_id, runner_id, session, message, transitions, record) do
    case apply_verdict(tenant_id, runner_id, session, message, transitions) do
      :ok -> {:ok, %{record: record, replayed?: true}}
      {:error, :stale_stage} -> {:ok, %{record: record, replayed?: true}}
      {:error, reason} -> {:error, reason}
    end
  end

  # RECORD FIRST, then transition. The other order cannot be repaired: a transition that
  # landed with no record leaves the resend re-attempting it, getting `stale_stage`, and
  # holding no record to recognise — so the verdict could never be stored at all.
  defp fresh(tenant_id, runner_id, session, message, digest, transitions) do
    with {:ok, record} <- insert_record(tenant_id, session, message, digest),
         :ok <- apply_verdict(tenant_id, runner_id, session, message, transitions) do
      {:ok, %{record: record, replayed?: false}}
    else
      # The unique index racing another delivery of the SAME verdict — a rejoin whose old
      # channel is still draining, two sockets, two nodes. Re-read and compare rather than
      # refusing: `already_recorded` is published as PERMANENT, so a conforming runner would
      # never resend and the documented close of this race could not happen.
      {:error, :unique_violation} ->
        raced(tenant_id, runner_id, session, message, digest, transitions)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp raced(tenant_id, runner_id, session, message, digest, transitions) do
    case in_tenant(tenant_id, fn -> existing(tenant_id, message.dispatch_id) end) do
      %TriageVerdictRecord{payload_digest: ^digest} = record ->
        replay(tenant_id, runner_id, session, message, transitions, record)

      _other ->
        {:error, :already_recorded}
    end
  end

  # `Repo.with_tenant/2` wraps its function's result, so a caller would otherwise see
  # `{:ok, {:ok, _}}`.
  defp in_tenant(tenant_id, fun) do
    case Repo.with_tenant(tenant_id, fun) do
      {:ok, result} -> result
      other -> other
    end
  end

  defp existing(tenant_id, dispatch_id) do
    Repo.one(
      from r in TriageVerdictRecord,
        where: r.tenant_id == ^tenant_id and r.dispatch_id == ^dispatch_id
    )
  end

  defp insert_record(tenant_id, session, message, digest) do
    verdict = Map.get(message, :verdict)

    attrs = %{
      outcome: verdict && verdict.outcome,
      confidence: verdict && verdict.confidence,
      payload: verdict && stringify(verdict),
      incomplete_reason: Map.get(message, :incomplete),
      detail: Map.get(message, :detail)
    }

    %TriageVerdictRecord{
      tenant_id: tenant_id,
      dispatch_id: message.dispatch_id,
      story_id: session.story_id,
      claim_epoch: message.claim_epoch,
      payload_digest: digest
    }
    |> TriageVerdictRecord.create_changeset(attrs)
    |> then(fn changeset -> in_tenant(tenant_id, fn -> Repo.insert(changeset) end) end)
    |> case do
      {:ok, record} ->
        {:ok, record}

      # BY NAME, not a catch-all. Collapsing every changeset failure into `already_recorded`
      # told a runner — permanently — that a DIFFERENT verdict was on file, when the real
      # cause was a CHECK constraint or a length validation, and that cause was never logged.
      # Only the unique index means "already there".
      {:error, %Ecto.Changeset{} = changeset} ->
        if unique_violation?(changeset),
          do: {:error, :unique_violation},
          else: {:error, {:invalid, Enum.map(changeset.errors, fn {f, _} -> to_string(f) end)}}
    end
  end

  defp unique_violation?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn {_field, {_message, opts}} ->
      Keyword.get(opts, :constraint) == :unique
    end)
  end

  # Atom keys are what the cast produces and jsonb round-trips as strings, so a digest taken
  # over the stored form would differ from one taken over the received form. Stored
  # stringified; the DIGEST is taken over the message and is what comparison uses either way.
  defp stringify(%{} = map) when not is_struct(map),
    do: Map.new(map, fn {k, v} -> {to_string(k), stringify(v)} end)

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(value), do: value

  # THE DRAFT BEFORE THE TRANSITIONS, for the reason the moduledoc gives: a story that reaches
  # `queued` carrying the stub row is work dispatched against a repository name and an issue
  # number, while a draft with no advance is simply queued by the next resend.
  #
  # Idempotent by construction — it writes the same values from the same recorded verdict — so
  # the replay path runs it too rather than assuming the first attempt got that far.
  defp apply_verdict(tenant_id, runner_id, session, message, transitions) do
    with :ok <- apply_draft(tenant_id, session, message) do
      advance_all(tenant_id, runner_id, session, message, transitions)
    end
  end

  # Only an accepted verdict drafts a story. An escalation or a rejection leaves the stub row
  # exactly as it is: nobody is going to implement it, and the reporter's own words are in the
  # intake record where a human reads them fenced.
  # ON `Loopctl.Repo` UNDER `with_tenant/2`, like every other read and write this module makes
  # and unlike `Loopctl.WorkBreakdown.Stories`, which is an `AdminRepo` context. The story is
  # tenant-scoped content, so RLS plus an explicit predicate is the convention for touching it
  # — and it keeps the draft on the SAME connection as the transitions that follow it, rather
  # than splitting one verdict's effects across two pools.
  defp apply_draft(tenant_id, session, %{verdict: %{outcome: "story", story: %{} = draft}}) do
    in_tenant(tenant_id, fn ->
      case Repo.one(
             from s in Story, where: s.id == ^session.story_id and s.tenant_id == ^tenant_id
           ) do
        nil -> {:error, :unknown_story_stage}
        story -> write_draft(tenant_id, story, draft)
      end
    end)
  end

  # `cast_triage_verdict/1` requires `story` when the outcome is `story` (its `story_pairing`
  # rule), so this clause is unreachable through the channel. It is here because the
  # alternative — falling through to the no-op below — would QUEUE the stub row: a runner
  # would be sent a story whose title is a repository name and an issue number, with no
  # acceptance criteria, which is work dispatched against nothing.
  defp apply_draft(_tenant_id, _session, %{verdict: %{outcome: "story"}}),
    do: {:error, {:invalid, ["story is required when outcome is story"]}}

  defp apply_draft(_tenant_id, _session, _message), do: :ok

  defp write_draft(tenant_id, story, draft) do
    attrs = %{
      title: Untrusted.sanitise(Map.get(draft, :title)),
      description: Untrusted.sanitise(Map.get(draft, :description)),
      acceptance_criteria: drafted_criteria(draft)
    }

    case story |> Story.update_changeset(attrs) |> Repo.update() do
      {:ok, updated} -> log_draft(tenant_id, updated)
      {:error, %Ecto.Changeset{}} -> {:error, :story_draft_invalid}
    end
  end

  # The content change is recorded like any other story update. NOT chained: the chain already
  # carries the transitions this draft precedes, and the verdict itself is stored whole in
  # `triage_verdicts` — this is the ordinary audit row that says a title stopped being
  # loopctl's stub and became the trio's draft, attributed to control rather than the runner.
  defp log_draft(tenant_id, story) do
    Audit.create_log_entry(tenant_id, %{
      entity_type: "story",
      entity_id: story.id,
      action: "story_drafted_by_triage",
      actor_type: "system",
      actor_label: @draft_actor,
      metadata: %{"criteria_count" => length(story.acceptance_criteria)}
    })

    :ok
  end

  # The wire carries plain strings; the column carries the `{id, description}` maps every
  # other producer of a story writes, and `ImplementerInput.story_object/2` reads back. Ids
  # are positional and loopctl's own, because the draft supplies none — and a criterion with
  # an id it chose itself would be a reporter-shaped string in a field the loop reasons about.
  defp drafted_criteria(%{acceptance_criteria: criteria}) when is_list(criteria) do
    criteria
    |> Enum.with_index(1)
    |> Enum.map(fn {text, index} ->
      %{"id" => "AC-#{index}", "description" => Untrusted.sanitise(text)}
    end)
  end

  defp drafted_criteria(_draft), do: []

  defp advance_all(_tenant_id, _runner_id, _session, _message, []), do: :ok

  defp advance_all(tenant_id, runner_id, session, message, [transition | rest]) do
    case Stages.advance(
           tenant_id,
           session.story_id,
           transition,
           opts(runner_id, session, message, transition)
         ) do
      {:ok, _row} -> advance_all(tenant_id, runner_id, session, message, rest)
      {:error, :not_found} -> {:error, :unknown_story_stage}
      {:error, reason} -> {:error, reason}
    end
  end

  defp opts(runner_id, session, message, {_from, to, _edge}) do
    [
      claim_epoch: message.claim_epoch,
      reason: reason_for(to, message),
      actor_label: "runner:" <> runner_id,
      # The runner's credential is a plain `api_keys` row that no dispatch minted, so its
      # lineage is genuinely empty and saying so is what stops `Stages.advance/4` reading an
      # absent lineage as a caller that forgot to resolve one. `:agent` keeps the human-only
      # edge out of reach whatever the default becomes — and `:triage_escalate` is reachable
      # here precisely because control, not the runner, is taking it.
      actor_role: :agent,
      actor_lineage: [],
      session_dispatch: {message.dispatch_id, session.slot_generation}
    ]
  end

  # ENUM VALUES ONLY. See the `apply/3` doc: the verdict's own escalation prose was written
  # by a session that had just read reporter text, and this string lands in an append-only
  # hash chain.
  defp reason_for(:escalated, %{incomplete: reason}) when is_binary(reason),
    do: "triage_verdict:" <> reason

  defp reason_for(:escalated, _message), do: "triage_verdict:escalate"
  defp reason_for(:failed, _message), do: "triage_verdict:reject"
  defp reason_for(_to, _message), do: nil
end
