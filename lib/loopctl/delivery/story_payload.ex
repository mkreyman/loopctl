defmodule Loopctl.Delivery.StoryPayload do
  @moduledoc """
  The `story` object of an `implement` dispatch, built from Postgres — or an escalation
  instead of a partial one (issue #803, contract 1.5.0).

  `Loopctl.Delivery.ImplementerInput.story_object/2` is the pure builder and the allowlist;
  this is the database half and the REFUSAL. A story that exceeds any cap the contract
  declares is not truncated to fit: a dropped acceptance criterion is a story built to the
  wrong spec, and an implementer cannot tell three criteria from four with the fourth cut.
  It is escalated to a human over `:session_escalated` — the edge that already exists for
  "this needs Mark" — and no dispatch is recorded or sent.

  ## Where the state lives

  Postgres owns the story. The wire carries a COPY, derived on each dispatch and stored
  nowhere: there is no cached payload to go stale, and nothing to reconcile after a crash.

  ## Retries

  `build/3` is a pure function of the story row and its options, so the same story yields a
  byte-identical object every time and a re-dispatch of one `dispatch_id` never carries a
  different story than the send it repeats. The bound that makes that true across an EDIT,
  rather than only within a moment, is the ledger's: `Loopctl.Runners.DispatchLedger` re-sends
  only a row still at `sent`, and refuses one already answered
  (`:dispatch_already_replied`). So the only re-dispatch that reaches a runner is one whose
  push was dropped before any session started — there is no session holding the older text to
  be inconsistent with.

  ## Partitions

  A dispatch that cannot be delivered leaves its ledger row `sent` with no `pushed_at`, and
  this module has written nothing at all — the object exists only inside the frame. The
  refusal path is the one that writes, and it writes one stage transition in one transaction,
  so a story is either dispatched or escalated and never both.

  ## Slow connections

  The object's byte cap (`RunnerStory.max_bytes/0`) is what bounds the frame, which is why it
  is enforced here, before the payload is handed to `Loopctl.Runners.dispatch/3`, rather than
  discovered by a socket closing mid-send.

  ## Where it runs

  In the dispatching caller's own process, on whichever node it happens to be, reading the
  RLS-enforced `Loopctl.Repo`. It supervises nothing and holds no state between calls.
  """

  import Ecto.Query

  require Logger

  alias Loopctl.Delivery.ImplementerInput
  alias Loopctl.Delivery.StageMachine
  alias Loopctl.Delivery.Stages
  alias Loopctl.Delivery.StoryStage
  alias Loopctl.Repo
  alias Loopctl.WorkBreakdown.Story

  @escalation_actor "control:dispatch"

  @type violation :: String.t()

  # `:unknown_story_stage` and `:no_escalation_edge` are NOT bare members: they arise only
  # inside the escalation and always reach the caller wrapped in `:escalation_failed`, so
  # listing them flat would have an exhaustive `case` writing a clause nothing reaches.
  @type error ::
          :not_found
          | {:story_not_dispatchable, [violation()]}
          | {:escalation_failed, escalation_error(), [violation()]}

  @type escalation_error ::
          :unknown_story_stage
          | {:no_escalation_edge, StageMachine.stage()}
          | Stages.advance_error()

  @doc """
  The story object for an `implement` dispatch of `story_id`, or an escalation.

  Returns `{:ok, object}` — string-keyed, ready to put under the dispatch payload's `"story"`
  key.

  `{:error, {:story_not_dispatchable, violations}}` means the story cannot be sent as it
  stands AND has been escalated: the stage row is at `escalated`, the violations are on the
  transition's event, and the caller must not dispatch. A row ALREADY at `escalated` — parked
  by an earlier attempt or by anything else — is this answer too, because the story is where
  this call wanted to put it. `{:error, {:escalation_failed, reason, violations}}` is the same
  refusal with the escalation itself refused — louder on purpose, and logged at error, because
  a story that is neither dispatchable nor parked is one nothing will pick up.

  ## Precondition: the story must be at a stage escalation can leave

  `:session_escalated` leaves the in-flight stages (`claimed` through `ci`), `merged` and
  `deployed`, and nothing else. That is satisfied by construction where a dispatch is
  composed — a story is CLAIMED before it is dispatched, and the ledger's own claim fence
  refuses a dispatch for a story no claim holds — so the precondition costs a caller nothing
  it was not already doing. Called at `queued`, `triaged` or a terminal stage, this cannot
  park the story, and it says so by name: `{:escalation_failed, {:no_escalation_edge, stage},
  violations}` rather than a bare `:invalid_transition` a caller has to guess at.

  ## Options

  Both required options are read at the TOP of the call, before the story is loaded, so a
  composer that omits one learns on its first ordinary dispatch instead of raising a KeyError
  on its first undispatchable story — which would turn a refusal into a crash in the caller.

  - `:claim_epoch` (required) — the epoch the caller's claim returned. The fence on the
    escalation, exactly as it is on every other transition.
  - `:actor_lineage` (required) — the dispatching caller's lineage, server-resolved. Entering
    `escalated` is a chained transition and `Stages.advance/4` refuses an absent lineage
    rather than letting an attested `[]` pass for one nobody resolved.
  - `:actor_label` — attribution, defaulting to `#{inspect(@escalation_actor)}`.
  - `:test_cases`, `:touches`, `:domain_reference` — passed through to
    `ImplementerInput.story_object/2`; see its docs for why they are options and not story
    fields.
  """
  @spec build(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) :: {:ok, map()} | {:error, error()}
  def build(tenant_id, story_id, opts) when is_binary(tenant_id) and is_binary(story_id) do
    # Read here rather than on the refusal path: they are only USED when a story is oversize,
    # and a required option that is only read on the rare branch is a required option nobody
    # discovers they are missing.
    escalation = [
      claim_epoch: Keyword.fetch!(opts, :claim_epoch),
      actor_lineage: Keyword.fetch!(opts, :actor_lineage),
      actor_label: Keyword.get(opts, :actor_label, @escalation_actor)
    ]

    with {:ok, story} <- fetch_story(tenant_id, story_id) do
      case ImplementerInput.story_object(story, opts) do
        {:ok, object} ->
          {:ok, object}

        {:error, {:story_not_dispatchable, violations}} ->
          refuse(tenant_id, story_id, violations, escalation)
      end
    end
  end

  defp fetch_story(tenant_id, story_id) do
    {:ok, story} =
      Repo.with_tenant(tenant_id, fn ->
        Repo.one(from s in Story, where: s.id == ^story_id and s.tenant_id == ^tenant_id)
      end)

    if story, do: {:ok, story}, else: {:error, :not_found}
  end

  # The refusal, and the whole reason this module is not just the pure builder: a story
  # loopctl cannot describe within the contract is a story a human has to look at, so it is
  # parked rather than left in the queue for the next dispatcher to fail on identically.
  defp refuse(tenant_id, story_id, violations, escalation) do
    case escalate(tenant_id, story_id, violations, escalation) do
      {:ok, _row} ->
        Logger.warning(
          "story not dispatchable, escalated: tenant_id=#{tenant_id} " <>
            "story_id=#{story_id} violations=#{inspect(Enum.take(violations, 5))} " <>
            "violation_count=#{length(violations)}",
          tenant_id: tenant_id,
          story_id: story_id
        )

        {:error, {:story_not_dispatchable, violations}}

      {:error, reason} ->
        # ERROR, and louder than the branch above on purpose: the escalated case is the
        # HARMLESS one — a human has the story. This one leaves it neither dispatchable nor
        # parked, so it is the outcome nothing downstream will pick up and nobody is watching
        # for. Which is exactly why `escalate/4` re-reads before it gets here: the loudest
        # signal in this module must not fire on a story that IS parked.
        Logger.error(
          "story not dispatchable AND NOT ESCALATED: tenant_id=#{tenant_id} " <>
            "story_id=#{story_id} escalation_error=#{inspect(reason)} " <>
            "violations=#{inspect(Enum.take(violations, 5))} " <>
            "violation_count=#{length(violations)}",
          tenant_id: tenant_id,
          story_id: story_id
        )

        {:error, {:escalation_failed, reason, violations}}
    end
  end

  defp escalate(tenant_id, story_id, violations, escalation) do
    case Stages.get(tenant_id, story_id) do
      nil ->
        {:error, :unknown_story_stage}

      %StoryStage{stage: stage} ->
        tenant_id
        |> attempt(story_id, stage, violations, escalation)
        |> settle_if_parked(tenant_id, story_id)
    end
  end

  # Attempts the transition, or names the missing edge. It NEVER decides whether the story
  # ended up parked — `escalate/4` pipes both outcomes through the one `settle_if_parked/3`
  # above.
  #
  # That single call site is the point. This used to ask the question twice: an early
  # `%StoryStage{stage: :escalated}` clause returned before any attempt, and a second re-read
  # sat on the advance's own result for the race. The early clause answered first, so the
  # round-2 test for the race never executed the re-read at all and the pipe deleted with the
  # whole suite green (#829 round 3, finding 1). Worse, the surviving call site was the one
  # reachable ONLY by a genuine mid-call race, which no in-process test can stage — so it
  # could never be covered. One call site, reached by the ordinary already-parked story, is
  # both simpler and the only version a test can hold.
  #
  # An already-parked row still spends no second `attempts` count and writes no second chain
  # entry: `escalated` has no `:session_escalated` edge OUT of it, so no transition is
  # attempted on it at all.
  #
  # The edge is checked against the machine's own table BEFORE the transition, so a stage
  # escalation cannot leave is named rather than reported as a bare `:invalid_transition` the
  # caller must decode. See the precondition on `build/3`.
  defp attempt(tenant_id, story_id, stage, violations, escalation) do
    if {stage, :escalated, :session_escalated} in StageMachine.transitions() do
      Stages.advance(
        tenant_id,
        story_id,
        {stage, :escalated, :session_escalated},
        escalation ++
          [reason: reason_text(violations), event_data: violation_event_data(violations)]
      )
    else
      {:error, {:no_escalation_edge, stage}}
    end
  end

  @doc """
  Answers "is the story parked anyway?" for a refusal that would otherwise be reported as a
  failure to park it. Internal to the escalation; public only so the RACE half can be tested
  without racing.

  Three refusals qualify, and all three mean the row is not where this call last read it:

  - `:stale_stage` — another writer moved it between the read and the compare-and-set.
  - `:stale_claim_epoch` — the same, plus a claim release. `Loopctl.Delivery.Stages` checks the
    epoch BEFORE the stage, so a racing park that also released the claim surfaces as this and
    never as `:stale_stage`. Confirmed by reading `transition/6`: `share_lock_story/2`, then
    the epoch rollback, then `compare_and_set/4`.
  - `{:no_escalation_edge, stage}` — including the ordinary case where the row is ALREADY at
    `escalated`, which has no `:session_escalated` edge leaving it.

  A row at `escalated` is the outcome this call wanted, whoever wrote it, so it is `:ok`.
  Anything else returns the original error unchanged, which is what keeps the module's loudest
  signal — "NOT ESCALATED" at `:error` — for the genuinely stranded story it was written for.
  One re-read, no recursion.

  The epoch is deliberately NOT compared, unlike `Loopctl.Delivery.Escalations.escalate/3`.
  That one is a SESSION claiming its own escalation, so an escalation under another epoch is
  somebody else's. This is control asking for the story to be PARKED; parked under any epoch
  is the outcome, and a human looks at it either way.
  """
  @spec settle_if_parked({:ok, StoryStage.t()} | {:error, term()}, Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, StoryStage.t()} | {:error, term()}
  def settle_if_parked(result, tenant_id, story_id)

  def settle_if_parked({:error, reason}, tenant_id, story_id)
      when reason in [:stale_stage, :stale_claim_epoch, :invalid_transition]
      when is_tuple(reason) and elem(reason, 0) == :no_escalation_edge do
    case Stages.get(tenant_id, story_id) do
      %StoryStage{stage: :escalated} = row -> {:ok, row}
      _other -> {:error, reason}
    end
  end

  def settle_if_parked(result, _tenant_id, _story_id), do: result

  # BOUNDED against the same cap `Stages` enforces, read from its accessor rather than
  # restated. Unbounded, this was the sibling of the reason truncation below and the same
  # failure: `list_violations/4` emits one message per offending item, nothing caps the number
  # of acceptance criteria a story may carry, and about 140 over-length items pushed the
  # encoded map past 8_000 — `advance/4` answered `:invalid_event_data` and the story was
  # neither dispatched NOR escalated, which is precisely the outcome the truncation exists to
  # prevent.
  #
  # The COUNT is exact and the list is a prefix, so a reader is never misled about how many
  # there were. Halving rather than dropping one at a time because the encode is what costs,
  # and a prefix that is a little shorter than it could be loses nothing: the full list is on
  # the return value and in the log.
  defp violation_event_data(violations) do
    fit(violations, length(violations))
  end

  defp fit(violations, 0) do
    %{"story_payload_violations" => [], "story_payload_violation_count" => length(violations)}
  end

  defp fit(violations, take) do
    candidate = %{
      "story_payload_violations" => Enum.take(violations, take),
      "story_payload_violation_count" => length(violations)
    }

    if byte_size(Jason.encode!(candidate)) <= Stages.max_event_data_bytes(),
      do: candidate,
      else: fit(violations, div(take, 2))
  end

  # Capped at the same bound `story_stages_text_bounds` holds the column to, read from the
  # machine rather than restated, so a story with many violations cannot produce a reason the
  # transition then refuses — which would turn "not dispatchable" into "not escalatable
  # either", the one outcome that leaves a story nowhere.
  defp reason_text(violations) do
    text =
      "loopctl did not dispatch this story: it does not satisfy the runner contract's story " <>
        "object, and a trimmed story would be built to the wrong spec. " <>
        Enum.join(violations, "; ")

    # CODEPOINTS, the unit the CHECK counts in — never `String.slice/2`, which counts
    # graphemes and would leave a 4000-grapheme reason with more codepoints than the column
    # takes.
    text
    |> String.to_charlist()
    |> Enum.take(StageMachine.max_reason_length())
    |> List.to_string()
  end
end
