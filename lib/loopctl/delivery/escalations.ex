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

  `reason` is written by the session, which is a model. It is stored ESCAPED FOR INVISIBLE
  CHARACTERS and otherwise verbatim — `Loopctl.Delivery.Stages.advance/4` runs it through
  `Untrusted.sanitise/1` before the bound is checked — so an operator reads what was actually
  said AND can see what was hidden in it. Prose is untouched; a bidirectional override, a
  zero-width run or a NUL becomes a visible `<U+XXXX>`.

  **The escape is NOT injective, and the honest statement of what it buys says so.** A session
  that writes the literal ASCII text `<U+202E>` produces a stored value identical to one
  produced by a real bidirectional override — `sanitise/1` is idempotent, so it cannot
  distinguish them and neither can a reader. So: a HIDDEN character always becomes visible,
  which is the property this is for; a VISIBLE one that looks like an escape becomes
  indistinguishable from a hidden one, which means a session can fabricate the appearance of
  an attack it did not make. That is a much smaller problem than text that silently lies about
  itself, and it is stated rather than left for a reader to discover.

  That is a deliberate reversal of the strict-verbatim rule this line used to state, and the
  reason is that the field is PERMANENT in two places nobody can edit: the column and, on a
  chained transition, the tenant's append-only hash chain. Text whose hidden characters are
  invisible is text that does not say what it appears to say, for ever. The NUL case decides
  it on its own: Postgres will not store one, so a reason containing one was refused outright
  and THE ESCALATION WAS LOST — a session asking for a human got nothing, over one byte.

  It is capped at the `story_stages_text_bounds` CHECK's bound, measured on the escaped text
  because that is what is stored, and never executed. Anything that puts it in front of a model renders it through
  `Loopctl.Delivery.Stages.escalation_block/1`, which fences it as untrusted data. The
  optional `payload` goes to the stage event's `data` under its own key and never to
  `story_stages` at all.
  """

  alias Loopctl.Delivery.StageMachine
  alias Loopctl.Delivery.Stages
  alias Loopctl.Delivery.StoryStage
  alias Loopctl.Progress
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
          # `resolve/3`'s own two, which name what an operator actually did wrong rather than
          # leaving the machine to answer `stale_stage` — the word it uses for a story that
          # moved under a runner.
          | {:not_escalated, StageMachine.stage()}
          | {:unresolvable_target, term()}
          | Stages.advance_error()
          # PROPAGATED VERBATIM by `prepare_story/6`'s `with`, which has no `else` (846.8
          # review round 2). `resolve/3`'s `:queued` path calls
          # `Progress.force_unclaim_story/3` and then `Progress.contract_story/4`, and every
          # refusal either returns is this function's refusal too. The three below are the
          # shapes those two specs admit that nothing above already covers — and the
          # changeset is the one that matters, because it is not an atom at all, so a caller
          # matching `{:error, atom}` on this type would never have seen it.
          #
          # `Progress.contract_story/4` is specced `{:error, atom() | ...}`, i.e. OPEN: an
          # atom it gains tomorrow propagates here without this type changing. That coupling
          # is named rather than papered over with a bare `atom()`, which would make this
          # type say nothing at all. `test/loopctl_web/controllers/
          # story_escalation_controller_test.exs` holds the rendered statuses against the
          # operation's `responses` map, so a new shape that renders an undeclared status
          # fails there.
          | :force_unclaim_failed
          | {:contract_mismatch, map()}
          | Ecto.Changeset.t()

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

  @doc """
  Moves an ESCALATED story off `escalated`, as a human (#803 design §8).

  The other half of `escalate/3`, and it had no caller of any kind: `:human_resolution` is in
  the stage machine, `Stages.advance/4` gates it, and nothing in `lib/` or on the API could
  take it. So a story a session parked for a person stayed parked for ever — including the
  one the loop's first end-to-end run left behind — and the affordance this module is named
  for was one-way.

  `to` is `:queued`, `:done` or `:failed`, which is what `StageMachine` allows out of
  `escalated`: send it back to be worked, accept it as finished, or close it as not going to
  happen.

  ## Who may call it

  A HUMAN principal, which the machine itself defines as a role of at least `:user` on a key
  NO DISPATCH MINTED — `human?/1` in `Loopctl.Delivery.Stages`. Both halves are passed through
  from the caller rather than asserted here: the route supplies the role from the
  authenticating key, and the lineage is server-resolved, so a session cannot resolve the
  escalation it raised by claiming to be a person.

  **A caller that fails that gate changes NOTHING.** The gate is asked through
  `Stages.precheck/2` before the claim is released, so a refused resolve leaves the story
  exactly as it found it: claim held, epoch unmoved, session credential alive, row still at
  `escalated`. It did not until #862 review round 3 — the release ran first, and a refusal
  arrived after the implementer's credential had already been revoked.

  ## The epoch

  Read fresh, not taken from the caller. An escalated story is not held by a claim — that is
  what escalating did to it — so there is no epoch the caller could be holding, and demanding
  one would mean an operator reading a number off the row before they could act on it. The
  compare-and-set is still the fence: the transition is refused unless the row is at
  `escalated` when it lands.
  """
  @spec resolve(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, StoryStage.t()} | {:error, error()}
  def resolve(tenant_id, story_id, opts) do
    to = Keyword.fetch!(opts, :to)
    transition = {:escalated, to, :human_resolution}

    # Fetched ONCE, here, and threaded — not re-fetched at each use. It reaches TWO writers,
    # not one: `Stages.advance/4` below, and `force_unclaim_story/3` under `prepare_story/6`,
    # which since #862 revokes the story's session dispatch and puts a `dispatch_revoked`
    # entry on the hash chain. That second one was passed `actor_label:` alone while this
    # function was holding the lineage, so `Progress`'s `Keyword.get(opts, :actor_lineage,
    # [])` wrote an EMPTY actor on it (#862 review round 2, finding 3).
    actor_lineage = Keyword.fetch!(opts, :actor_lineage)

    # Built ONCE and used TWICE — by the precheck and by the advance — so the attribution the
    # gate JUDGES is necessarily the attribution the transition RECORDS. Two separately
    # assembled keyword lists would let those drift, which on a human-only edge is the whole
    # of the gate.
    advance_opts = [
      reason: Keyword.get(opts, :reason),
      actor_label: Keyword.get(opts, :actor_label),
      actor_role: Keyword.fetch!(opts, :actor_role),
      actor_lineage: actor_lineage
    ]

    # THE HUMAN GATE IS ASKED BEFORE ANYTHING IS DESTROYED, and that ordering is the fix for
    # #862 review round 3, finding 1. `prepare_story/6` RELEASES THE CLAIM — it has to, since
    # the release bumps the epoch this transition is then fenced on — and since #862 the
    # release also revokes the story's session credential and cascades to every descendant
    # dispatch and its `api_keys` row.
    #
    # Run in the old order, that made a REFUSED resolve destructive. A dispatch-minted
    # `:user`-role key is mintable (`@roles` in `Loopctl.Dispatches.Dispatch`) and clears the
    # route's `role: :user` plug, so a SESSION could POST `to: queued` on any escalated story:
    # the claim was released, the epoch bumped, the implementer's live credential and its
    # whole subtree revoked, the story re-contracted — and only THEN did `Stages.human?/1`
    # (`lib/loopctl/delivery/stages.ex:1127-1130`, which requires `actor_lineage == []`)
    # refuse it. The caller got a refusal; the implementing agent got a dead key.
    # `LoopctlWeb.StoryEscalationController` publishes that gate's purpose to callers in its
    # `escalate` operation description — "so a session cannot escalate and then resolve its
    # own escalation" — and the separation was being enforced one step AFTER the damage.
    #
    # `Stages.precheck/2` is the SAME guard chain `advance/4` runs, not a copy of it, so this
    # cannot answer differently from the advance that follows. It decides only what is
    # decidable without the row; `:stale_stage` and `:stale_claim_epoch` still belong to the
    # transaction, which is why `at_escalated/1` stays ahead of it — a story that is not
    # escalated is named as such rather than answered with a gate error about a transition it
    # was never going to take.
    with :ok <- resolvable(to),
         {:ok, row} <- live_row(tenant_id, story_id),
         :ok <- at_escalated(row),
         :ok <- Stages.precheck(transition, advance_opts),
         {:ok, epoch} <- prepare_story(tenant_id, story_id, to, row, opts, actor_lineage) do
      Stages.advance(tenant_id, story_id, transition, [claim_epoch: epoch] ++ advance_opts)
    end
  end

  # SENDING A STORY BACK TO `queued` HAS TO MAKE IT PLACEABLE, or it is a stage row that says
  # one thing while the story says another. Escalating does NOT release the claim — the story
  # is still assigned to the session that stopped, at `:implementing` — and
  # `Placement.claimable/2` requires `agent_status == :contracted` AND stage `queued`. Moving
  # the row alone left a story an operator had deliberately re-queued that no placement would
  # take, and no lease recovers it either: the release sets `:pending`, which is not
  # `:contracted` either.
  #
  # So the claim goes back and the story is re-contracted, in that order, and the epoch the
  # transition is fenced on is read AFTER both — releasing bumps it.
  #
  # `done` and `failed` prepare nothing: the story is finished with, and re-contracting it
  # would be inventing work.
  defp prepare_story(tenant_id, story_id, :queued, _row, opts, actor_lineage) do
    label = Keyword.get(opts, :actor_label)

    with {:ok, story} <- release_claim(tenant_id, story_id, label, actor_lineage),
         {:ok, story} <- recontract(tenant_id, story, label) do
      {:ok, story.claim_epoch}
    end
  end

  defp prepare_story(_tenant_id, _story_id, _to, row, _opts, _actor_lineage),
    do: {:ok, row.claim_epoch}

  # Idempotent by `force_unclaim_story/3`'s own design: a story already at `:pending` — its
  # claim released by the lease while it sat escalated — passes through with its current epoch.
  #
  # The lineage is FORWARDED, not defaulted: this call revokes the story's session dispatch
  # (#862) and is therefore an audit-chain writer, so `resolve/3`'s server-resolved caller
  # lineage has to reach it rather than `Progress`'s `Keyword.get(opts, :actor_lineage, [])`
  # default, which writes the shape the tenant's own operator key writes.
  #
  # ON EVERY PATH `resolve/3` CAN TAKE TODAY THE TWO ARE THE SAME VALUE, and this comment says
  # so rather than claiming a mechanism the code no longer has. `:human_resolution` is a
  # human-only edge, `Stages.human?/1` requires `actor_lineage == []`, and since #862 review
  # round 3 that gate is checked BEFORE this call — so the only lineage that reaches here is
  # `[]`. The forwarding is what keeps the attribution correct if a future edge into
  # `prepare_story/6` is not human-only; it is not something a test can currently falsify
  # through `resolve/3`, and pretending otherwise is how an inert guard gets believed.
  defp release_claim(tenant_id, story_id, label, actor_lineage) do
    Progress.force_unclaim_story(tenant_id, story_id,
      actor_label: label,
      actor_lineage: actor_lineage
    )
  end

  # `pending -> contracted` is the only transition into the state a placement needs, and a
  # story that is somehow already `contracted` is left alone rather than refused: the operator
  # asked for a placeable story and it is one.
  defp recontract(_tenant_id, %{agent_status: :contracted} = story, _label), do: {:ok, story}

  defp recontract(tenant_id, story, label) do
    Progress.contract_story(tenant_id, story.id, %{},
      actor_label: label,
      skip_contract_check: true
    )
  end

  defp resolvable(to) do
    if {:escalated, to, :human_resolution} in StageMachine.transitions(),
      do: :ok,
      else: {:error, {:unresolvable_target, to}}
  end

  # A story that is not escalated has nothing to resolve, and saying so is better than the
  # machine's `:stale_stage` — which is the same word it uses for a story that moved under a
  # runner, and would send an operator looking for a race that did not happen.
  defp at_escalated(%StoryStage{stage: :escalated}), do: :ok
  defp at_escalated(%StoryStage{stage: stage}), do: {:error, {:not_escalated, stage}}
end
