defmodule Loopctl.Delivery.Escalations do
  @moduledoc """
  Escalation as a POSITIVE AFFORDANCE for an unattended session (issue #803, design §8).

  A headless `claude -p` has no `AskUserQuestion` at all, and nothing fires when the model
  wanted to ask: no tool call is attempted, so neither `PreToolUse` nor `PermissionDenied`
  sees anything. There is therefore no hook that can DETECT the wish to escalate — the
  session has to have a thing it can DO. `POST /api/v1/stories/:id/escalate` is that thing on
  the control side, and the runner's `priv/bin/loop-escalate` is its local twin; both end at
  the one `:session_escalated` edge, so the chain entry is identical whichever was used.

  ## What it is not

  It is not a way to reach a different verdict. The story goes to `escalated` and stops; only
  a HUMAN principal moves it off, over `:human_resolution`, which
  `Loopctl.Delivery.Stages.advance/4` gates on a role of at least `:user` holding a key no
  dispatch minted. A session cannot escalate and then resolve its own escalation.

  ## Who may call it

  The story's CLAIMANT, on the agent key its dispatch minted, presenting the `claim_epoch`
  its claim returned. Three separate conditions, each doing something the others do not:

  - `exact_role: :agent` on the route, the same gate `claim`/`start`/`unclaim` carry. An
    orchestrator or a user key is 403'd: a human with a `:user` key resolves an escalation,
    it does not raise one, and the route must not become a second way into the stage machine
    for a higher-privileged key.
  - `assigned_agent_id == the key's agent_id`, checked here. Escalating parks a story until
    Mark looks at it, so it is not something one agent does to another agent's work.
  - the epoch fence, applied by `Stages.advance/4` under the story's share lock. That is what
    makes the claimant check safe to do in a separate read: `assigned_agent_id` only changes
    when a claim is released, and every release bumps the epoch, so a claim that ended
    between the two reads is refused by the fence rather than acted on.

  ## Retries

  Safe to repeat. The transition is a compare-and-set, so the copy of a request whose first
  attempt committed finds the row already at `escalated`; `escalate/3` then re-reads it and,
  when it is at `escalated` under the CALLER'S OWN epoch, answers `{:ok, row}` with no second
  transition, no second `attempts` count and no second chain entry. Under a DIFFERENT epoch it
  is not this caller's escalation and the fence refuses it. The same read is what makes a
  concurrent duplicate — two copies of one retry in flight at once — resolve to the same
  answer whichever order they land in.

  ## Partitions, and where the state lives

  Postgres, and the reason matters here more than elsewhere: an escalation is the one
  transition whose whole purpose is to survive the session that raised it. The session is
  expected to stop immediately afterwards, so nothing in its process may hold the fact. A
  session that escalates and then loses the network wrote the row before it stopped, or did
  not write it at all — and in the second case its runner reports the same escalation over
  the `stage` channel when it comes back, which lands on the same edge and the same row.

  ## Untrusted text

  `reason` is written by the session, which is a model. It is stored VERBATIM so an operator
  reads what was actually said, capped at the `story_stages_text_bounds` CHECK's bound, and
  never executed. Anything that puts it in front of a model renders it through
  `Loopctl.Delivery.Stages.escalation_block/1`, which fences it as untrusted data. The
  optional `payload` goes to the stage event's `data` under its own key and never to
  `story_stages` at all.
  """

  alias Loopctl.Delivery.StageMachine
  alias Loopctl.Delivery.Stages
  alias Loopctl.Delivery.StoryStage
  alias Loopctl.Repo
  alias Loopctl.WorkBreakdown.Story

  import Ecto.Query

  @type error ::
          :not_found
          | :unknown_story_stage
          | :not_claimant
          | :stale_claim_epoch
          | :stale_stage
          | :invalid_transition
          | :reason_required
          | :invalid_reason
          | :invalid_event_data
          | :busy
          | Stages.advance_error()

  @doc """
  Escalates `story_id` to a human on behalf of its claiming agent. Returns the story's stage
  row, at `escalated`.

  ## Options

  - `:claim_epoch` (required) — the epoch the caller's claim returned
  - `:agent_id` (required) — the calling key's agent, compared against `assigned_agent_id`
  - `:reason` (required) — why, in the session's own words. Untrusted; see the moduledoc
  - `:payload` — an optional JSON-encodable map recorded on the stage event
  - `:actor_label` — attribution, SERVER-resolved by the caller
  - `:actor_lineage` (required) — the caller's dispatch lineage, SERVER-resolved from its key.
    Required rather than defaulted: entering `escalated` is a chained transition, and
    `Stages.advance/4` refuses an absent lineage so that an attested `[]` cannot be confused
    with a caller that never resolved one.
  """
  @spec escalate(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, StoryStage.t()} | {:error, error()}
  def escalate(tenant_id, story_id, opts) do
    epoch = Keyword.fetch!(opts, :claim_epoch)

    with :ok <- claimant_and_epoch(tenant_id, story_id, Keyword.fetch!(opts, :agent_id), epoch),
         {:ok, row} <- live_row(tenant_id, story_id),
         :continue <- unless_already_escalated(row, epoch) do
      advance(tenant_id, story_id, row, opts)
    else
      {:already, row} -> {:ok, row}
      {:error, reason} -> {:error, reason}
    end
  end

  # Read on the RLS `Loopctl.Repo`, the repo `Stages` uses, so the escalation path never
  # touches `AdminRepo`'s three-connection pool for a check every escalating session makes.
  #
  # The epoch is checked HERE as well as inside `Stages.advance/4` — not as belt and braces,
  # but because the replay short-circuit below runs BETWEEN the two and would otherwise be
  # decided on the stage ROW's epoch, which is what the row was last written under and not
  # whether this caller's claim is still live. A zombie presenting the epoch its own stale
  # row still carried would have been answered `{:ok, row}`. The authoritative read inside
  # the transition stays: this one cannot be atomic with the write, and only that one is.
  defp claimant_and_epoch(tenant_id, story_id, agent_id, epoch) do
    {:ok, story} =
      Repo.with_tenant(tenant_id, fn ->
        Repo.one(
          from s in Story,
            where: s.id == ^story_id and s.tenant_id == ^tenant_id,
            select: %{assigned_agent_id: s.assigned_agent_id, claim_epoch: s.claim_epoch}
        )
      end)

    cond do
      is_nil(story) ->
        {:error, :not_found}

      # An UNCLAIMED story is not this caller's, and a key with no agent must never satisfy
      # the check by matching that nil. Both halves of the comparison have to be a real
      # agent, which is why this is not `story.assigned_agent_id == agent_id` alone.
      is_nil(story.assigned_agent_id) or is_nil(agent_id) ->
        {:error, :not_claimant}

      story.assigned_agent_id != agent_id ->
        {:error, :not_claimant}

      story.claim_epoch != epoch ->
        {:error, :stale_claim_epoch}

      true ->
        :ok
    end
  end

  defp live_row(tenant_id, story_id) do
    case Stages.get(tenant_id, story_id) do
      nil -> {:error, :unknown_story_stage}
      row -> {:ok, row}
    end
  end

  # The replay, taken before the transition is attempted as well as after it is refused: a
  # session that escalated, stopped, and was restarted by its runner sends the same call
  # again, and it must not spend an `attempts` count or write a second chain entry. Under
  # another epoch it is somebody else's escalation and the fence below refuses it.
  defp unless_already_escalated(%StoryStage{stage: :escalated, claim_epoch: epoch} = row, epoch),
    do: {:already, row}

  defp unless_already_escalated(_row, _epoch), do: :continue

  # The FIRST attempt, from the row `escalate/3` read. A `:stale_stage` here is recovered
  # once; every other answer is the caller's.
  defp advance(tenant_id, story_id, row, opts) do
    case attempt(tenant_id, story_id, row, opts) do
      {:error, :stale_stage} -> after_stale_stage(tenant_id, story_id, opts)
      result -> result
    end
  end

  # One transition attempt and nothing else. Split out from `advance/4` so the retry below
  # cannot re-enter the recovery: with the recovery inside the only attempt function, a story
  # a runner keeps advancing would have recursed without bound.
  defp attempt(tenant_id, story_id, row, opts) do
    transition = {row.stage, :escalated, :session_escalated}

    advance_opts = [
      claim_epoch: Keyword.fetch!(opts, :claim_epoch),
      reason: Keyword.get(opts, :reason),
      event_data: Keyword.get(opts, :payload),
      actor_label: Keyword.get(opts, :actor_label),
      actor_role: :agent,
      # `fetch!`, never a default (#824 round 3). `Stages.advance/4` refuses an ABSENT
      # `:actor_lineage` on a chained transition precisely so that "resolved, and empty"
      # cannot be confused with "forgot to resolve" — and defaulting to `[]` here defeated
      # that refusal for every caller of this module. An empty list is an attested absence
      # and is still accepted; it just has to be stated.
      actor_lineage: Keyword.fetch!(opts, :actor_lineage)
    ]

    Stages.advance(tenant_id, story_id, transition, advance_opts)
  end

  # A `:stale_stage` here is USUALLY not a caller error at all: the caller's own runner is
  # advancing the story over the channel at the same time, so the row moved between the read
  # and the compare-and-set. Escalating from the NEW stage is almost always just as valid —
  # every in-flight stage has a `:session_escalated` edge — and returning 409 lost the
  # escalation outright, because neither this context nor the MCP tool retries (#824 round 2).
  #
  # So: re-read, and if it is a concurrent copy of this same request, answer with its row;
  # otherwise take the transition from where the story ACTUALLY is, ONCE.
  #
  # Once, and no more. The retry is bounded because the thing it races — a runner walking its
  # own story forward — can keep going indefinitely, and an unbounded retry against it is a
  # spin, not a fix. A second `:stale_stage` is returned, and by then it is worth telling the
  # caller rather than trying again.
  defp after_stale_stage(tenant_id, story_id, opts) do
    epoch = Keyword.fetch!(opts, :claim_epoch)

    with {:ok, current} <- live_row(tenant_id, story_id),
         :continue <- unless_already_escalated(current, epoch) do
      retry_from(tenant_id, story_id, current, opts)
    else
      {:already, escalated} -> {:ok, escalated}
      {:error, reason} -> {:error, reason}
    end
  end

  # The retry, from the stage the re-read found, through `attempt/4` and NOT `advance/4` — so
  # a second `:stale_stage` is returned rather than recovered again. `:invalid_transition`
  # means the story has moved somewhere a session may not escalate from (past the merge), and
  # that is the caller's answer rather than a third read.
  defp retry_from(tenant_id, story_id, row, opts),
    do: attempt(tenant_id, story_id, row, opts)

  @doc """
  The stages a session may escalate FROM — the ones a claim holds it in.

  Read off the machine rather than restated, so it is the same set
  `StageMachine.runner_transitions/0` publishes on the wire.
  """
  @spec escalatable_stages() :: [StageMachine.stage()]
  def escalatable_stages do
    for {from, :escalated, :session_escalated} <- StageMachine.transitions(), do: from
  end
end
