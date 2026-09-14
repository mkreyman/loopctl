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

  @type error ::
          :not_found
          | :unknown_story_stage
          | {:story_too_large, [violation()]}
          | {:escalation_failed, term(), [violation()]}

  @doc """
  The story object for an `implement` dispatch of `story_id`, or an escalation.

  Returns `{:ok, object}` — string-keyed, ready to put under the dispatch payload's `"story"`
  key.

  `{:error, {:story_too_large, violations}}` means the story broke a cap AND has been
  escalated: the stage row is at `escalated`, the violations are on the transition's event,
  and the caller must not dispatch. `{:error, {:escalation_failed, reason, violations}}` is
  the same refusal with the escalation itself refused — louder on purpose, because a story
  that is neither dispatchable nor parked is one nothing will pick up.

  ## Options

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
    with {:ok, story} <- fetch_story(tenant_id, story_id) do
      case ImplementerInput.story_object(story, opts) do
        {:ok, object} -> {:ok, object}
        {:error, {:story_too_large, violations}} -> refuse(tenant_id, story_id, violations, opts)
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
  defp refuse(tenant_id, story_id, violations, opts) do
    Logger.warning(
      "story too large to dispatch: tenant_id=#{tenant_id} story_id=#{story_id} " <>
        "violations=#{inspect(violations)}",
      tenant_id: tenant_id,
      story_id: story_id
    )

    case escalate(tenant_id, story_id, violations, opts) do
      {:ok, _row} -> {:error, {:story_too_large, violations}}
      {:error, reason} -> {:error, {:escalation_failed, reason, violations}}
    end
  end

  defp escalate(tenant_id, story_id, violations, opts) do
    case Stages.get(tenant_id, story_id) do
      nil ->
        {:error, :unknown_story_stage}

      %StoryStage{stage: :escalated} = row ->
        # Already parked, by this caller's own earlier attempt or by anything else. Re-parking
        # it would spend a second `attempts` count and write a second chain entry for one
        # story that was too large once.
        {:ok, row}

      %StoryStage{stage: stage} ->
        Stages.advance(tenant_id, story_id, {stage, :escalated, :session_escalated},
          claim_epoch: Keyword.fetch!(opts, :claim_epoch),
          actor_lineage: Keyword.fetch!(opts, :actor_lineage),
          actor_label: Keyword.get(opts, :actor_label, @escalation_actor),
          reason: reason_text(violations),
          event_data: %{"story_payload_violations" => violations}
        )
    end
  end

  # Capped at the same bound `story_stages_text_bounds` holds the column to, read from the
  # machine rather than restated, so a story with many violations cannot produce a reason the
  # transition then refuses — which would turn "too large to dispatch" into "too large to
  # escalate", the one outcome that leaves a story nowhere.
  defp reason_text(violations) do
    text =
      "loopctl did not dispatch this story: it exceeds the runner contract's caps, and a " <>
        "truncated story would be built to the wrong spec. " <> Enum.join(violations, "; ")

    # CODEPOINTS, the unit the CHECK counts in — never `String.slice/2`, which counts
    # graphemes and would leave a 4000-grapheme reason with more codepoints than the column
    # takes.
    text
    |> String.to_charlist()
    |> Enum.take(StageMachine.max_reason_length())
    |> List.to_string()
  end
end
