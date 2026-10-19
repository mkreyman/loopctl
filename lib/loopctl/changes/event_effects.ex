defmodule Loopctl.Changes.EventEffects do
  @moduledoc """
  What applying ONE chg event does to loopctl's state — the single seam event application goes
  through (Epic 47 PRD §5).

  `Loopctl.Changes.Events` calls `apply_event/2` once per event, in `event_seq` order, inside
  the transaction that holds the change's cursor lock and that records the event as applied
  and appends it to the audit chain. Whatever this returns is stored on the event row as its
  `effect`; a value returned here is never a reason to leave the event unapplied, because an
  unapplied event would hold every later one behind a gap that never fills.

  ## The binding (US-47.3)

  `submitted` with a `data.story_id` binds the change to that story
  (`Loopctl.Changes.bind_in_tenant_transaction/3`, PRD §4). The submitter is the webhook, a
  machine caller with no agent and no lineage, so a binding it makes is always
  `submitter_not_claimant` and never touches custody. A refusal (the change bound to another
  story, or superseded) is recorded as the effect, not raised. `story_id: null` binds nothing.

  ## The stage mapping (US-47.4, PRD §5's table)

  An event moves the stage of the story its change is CURRENTLY bound to — the binding is the
  truth, never an id in the payload — and of no other:

  | event | edge |
  |---|---|
  | `submitted` (any revision) | `implementing -> reviewing`, `:forward` |
  | `review_findings` | `reviewing -> implementing`, `:review_findings` |
  | `review_approved` (`by: model` or `policy`) and `check_passed` on the same revision | `reviewing -> ci`, `:change_ready` |
  | `landed` | `ci -> merged`, `:forward`, `merge_sha` = `data.merge_sha` (the new trunk commit) |
  | `deployed` | `merged -> deployed`, `:forward` |
  | `verified` | none: `trunk_verified_sha` = `data.sha` on the stage row |
  | `reverted`, at `merged` or `deployed` | `-> implementing`, `:reverted`, keeping the claim |
  | `reverted`, at `verified` | `-> escalated`, `:reverted_after_verify` |
  | `reverted`, at `done` | none: the revert goes on the story's history and opens a new intake issue |

  - `pr_open` is never a target: a chg change has no pull request
    (`Loopctl.Delivery.Stages` also refuses it to any writer on a bound story).
  - An event whose target is the row's CURRENT stage is a recorded no-op (a second
    `submitted` while review is still running).
  - The pair that makes a change ready is judged on the revision chg reviewed: whichever of
    `review_approved` and `check_passed` arrives second takes the edge, and a pair for a
    revision an EARLIER event already superseded moves nothing.
  - An edge the machine does not allow from where the story is escalates over
    `:change_outside_lifecycle` (`Loopctl.Delivery.Escalations.escalate_as_control/3`), and
    the event is recorded; the stage is never forced. A story already `escalated` is a human's
    and stays where it is, with the event on its history; a `done` or `failed` story has
    nowhere to go.
  - `deployed` is not emitted by chg v1 — loopctl's own post-deploy path keeps driving
    `merged -> deployed` — and is mapped for when it is.
  - Every other kind (`review_requested`, `check_failed`, `conflict`, `ready`, anything chg
    adds later) is recorded and moves nothing (AC-47.3.6).

  ## In the event's transaction, and nothing outside it

  Every stage move happens HERE, inside the event's transaction
  (`Loopctl.Delivery.Stages.advance_in_tenant_transaction/4`), so an event applies with its
  stage effect and its audit entry or not at all, and contention is the event's own retryable
  `:busy`. The story and its stage row are locked FIRST
  (`Stages.lock_for_control_in_tenant_transaction/2`), before this event binds or appends
  anything to the chain, and the edge is decided on that locked row — so the transition is one
  the row allows and cannot be refused for a reason that would roll the event back. Nothing
  here reaches the network: the issue a revert after `done` opens is an outbox row
  (`Loopctl.Changes.RevertIssues`) drained later.

  ## Custody

  The webhook holds no key, so the actor of every move is control: `actor_role: :agent`, an
  attested-empty lineage, the label `#{inspect("chg:change_events")}`. That keeps every
  human-only edge out of reach, and NOTHING here writes `assigned_agent_id` or
  `implementer_dispatch_id`: who submitted a change is information, never custody (PRD §4).

  ## Return

  `{:ok, effect, pending}`: `effect` is a JSON-safe map stored on the event — `"stage"` says
  what the mapping did; `pending` is a list of things to finish after commit
  (`after_commit/1`).
  """

  import Ecto.Query

  require Logger

  alias Loopctl.Audit
  alias Loopctl.AuditChain
  alias Loopctl.Changes
  alias Loopctl.Changes.Binding
  alias Loopctl.Changes.Event
  alias Loopctl.Changes.RevertIssues
  alias Loopctl.Delivery.Escalations
  alias Loopctl.Delivery.StageMachine
  alias Loopctl.Delivery.Stages
  alias Loopctl.Delivery.StoryStage
  alias Loopctl.GitSha
  alias Loopctl.Repo

  # The webhook is a machine caller: no API key, so no agent and no lineage (PRD §5). It can
  # bind a change, which is informational, and can never perform a custody act.
  @machine_submitter %{agent_id: nil, actor_lineage: []}

  @actor_label "chg:change_events"

  # The approvers chg names (PRD §5). A policy auto-approval takes the same edge; what it means
  # for custody is US-47.5's.
  @approvers ["model", "policy"]

  # What of an event's `data` the story's history keeps: the ids and shas, never the failing
  # tests, which can run to the body cap and belong on the issue a revert opens.
  @history_keys ~w(merge_sha sha landed_sha revert_sha revert_change_id verification_id)

  @type pending :: [{:bind, Changes.pending_bind()} | {:entry, AuditChain.Entry.t()}]

  @doc "Applies `event` for `tenant_id`, inside the caller's tenant transaction."
  @spec apply_event(Ecto.UUID.t(), Event.t()) :: {:ok, map(), pending()}
  def apply_event(tenant_id, %Event{} = event) do
    story_id = target_story_id(tenant_id, event)
    locked = lock_target(tenant_id, story_id)
    {effect, pending} = bind(tenant_id, event)

    case current_story(tenant_id, event, story_id, locked) do
      nil ->
        {:ok, effect, pending}

      %{} = target ->
        {stage, more} = stage_effect(tenant_id, event, target)
        {:ok, Map.put(effect, "stage", stage), pending ++ more}
    end
  end

  @doc "Finishes what `apply_event/2` left pending, after the caller's transaction commits."
  @spec after_commit(pending()) :: :ok
  def after_commit(pending) do
    Enum.each(pending, fn
      {:bind, bind} -> Changes.after_bind_commit(bind)
      {:entry, entry} -> AuditChain.announce_entry(entry)
    end)
  end

  # ── which story ─────────────────────────────────────────────────────────────

  # The story the change is bound to, or — for a `submitted` that will bind it now — the story
  # it names. Read BEFORE the bind so the story is locked before anything appends to the chain.
  defp target_story_id(tenant_id, %Event{} = event) do
    case change_binding(tenant_id, event) do
      %Binding{story_id: story_id} -> story_id
      nil -> named_story_id(event)
    end
  end

  defp named_story_id(%Event{kind: "submitted", data: %{"story_id" => id}}) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> uuid
      :error -> nil
    end
  end

  defp named_story_id(_event), do: nil

  defp change_binding(tenant_id, %Event{repo: repo, change_id: change_id}) do
    Repo.one(
      from b in Binding,
        where: b.tenant_id == ^tenant_id and b.repo == ^repo and b.change_id == ^change_id
    )
  end

  defp lock_target(_tenant_id, nil), do: nil

  defp lock_target(tenant_id, story_id) do
    case Stages.lock_for_control_in_tenant_transaction(tenant_id, story_id) do
      {:ok, locked} -> locked
      {:error, :not_found} -> nil
    end
  end

  # The mapping applies only to the story the change is CURRENTLY bound to, read after the bind
  # so a `submitted` that just bound it counts. A superseded binding moves nothing: the story
  # follows another change now.
  defp current_story(tenant_id, event, story_id, %{} = locked) do
    case change_binding(tenant_id, event) do
      %Binding{story_id: ^story_id, superseded_at: nil} -> Map.put(locked, :story_id, story_id)
      _other -> nil
    end
  end

  defp current_story(_tenant_id, _event, _story_id, nil), do: nil

  # ── the binding (US-47.3) ───────────────────────────────────────────────────

  defp bind(tenant_id, %Event{kind: "submitted"} = event) do
    case Map.get(event.data, "story_id") do
      nil ->
        {%{"effect" => "recorded", "binding" => "no_story"}, []}

      story_id ->
        {:ok, {outcome, _tenant_id, _input} = pending} =
          Changes.bind_in_tenant_transaction(
            tenant_id,
            %{story_id: story_id, repo: event.repo, change_id: event.change_id},
            @machine_submitter
          )

        {%{"effect" => "recorded", "binding" => describe(outcome)}, [{:bind, pending}]}
    end
  end

  defp bind(_tenant_id, %Event{}), do: {%{"effect" => "recorded"}, []}

  defp describe({:bound, %Binding{id: id}, _entry}), do: %{"outcome" => "bound", "id" => id}
  defp describe({:existing, %Binding{id: id}}), do: %{"outcome" => "existing", "id" => id}
  defp describe({:unbound, _entry}), do: %{"outcome" => "unbound"}

  defp describe({:refused, %Ecto.Changeset{}}),
    do: %{"outcome" => "refused", "reason" => "invalid_story_id"}

  defp describe({:refused, reason}) when is_atom(reason),
    do: %{"outcome" => "refused", "reason" => Atom.to_string(reason)}

  # ── the stage mapping (US-47.4) ─────────────────────────────────────────────

  defp stage_effect(_tenant_id, _event, %{row: nil}), do: {%{"outcome" => "no_stage_row"}, []}

  # A row behind its story's epoch is fenced against EVERY writer; nothing here can move it,
  # and saying so is better than a refusal that would roll the event back.
  defp stage_effect(_tenant_id, event, %{row: %StoryStage{} = row, claim_epoch: epoch})
       when row.claim_epoch != epoch do
    Logger.warning(
      "change event found a stage row behind its story's epoch; nothing moved: " <>
        "tenant_id=#{row.tenant_id} story_id=#{row.story_id} change_id=#{event.change_id} " <>
        "event_seq=#{event.event_seq}"
    )

    {%{"outcome" => "stale_row", "at" => Atom.to_string(row.stage)}, []}
  end

  defp stage_effect(tenant_id, event, %{row: %StoryStage{} = row} = target) do
    tenant_id
    |> intent(event, row)
    |> realise(tenant_id, event, target)
  end

  # What the event asks for, judged on the locked row. Pure but for the pair read.
  defp intent(_tenant_id, %Event{kind: "submitted"}, _row),
    do: {:move, :reviewing, :forward, []}

  defp intent(_tenant_id, %Event{kind: "review_findings"}, _row),
    do: {:move, :implementing, :review_findings, []}

  defp intent(tenant_id, %Event{kind: kind} = event, _row)
       when kind in ["review_approved", "check_passed"],
       do: ready_intent(tenant_id, event)

  defp intent(_tenant_id, %Event{kind: "landed", data: data}, _row) do
    case Map.get(data, "merge_sha") do
      sha when is_binary(sha) ->
        if GitSha.valid?(sha),
          do: {:move, :merged, :forward, [merge_sha: sha]},
          else: {:outside, "landed named no valid merge_sha"}

      _missing ->
        {:outside, "landed named no valid merge_sha"}
    end
  end

  defp intent(_tenant_id, %Event{kind: "deployed", data: data}, _row),
    do: {:move, :deployed, :forward, release_effect(data)}

  defp intent(_tenant_id, %Event{kind: "verified", data: data}, _row),
    do: {:trunk_verified, Map.get(data, "sha")}

  defp intent(_tenant_id, %Event{kind: "reverted"}, %StoryStage{stage: :verified}),
    do: {:escalate, :reverted_after_verify}

  defp intent(_tenant_id, %Event{kind: "reverted"}, %StoryStage{stage: :done}),
    do: :revert_after_done

  defp intent(_tenant_id, %Event{kind: "reverted"}, _row),
    do: {:move, :implementing, :reverted, []}

  defp intent(_tenant_id, %Event{}, _row), do: :unmapped

  defp release_effect(%{"release" => release}) when is_binary(release) and release != "",
    do: [release_id: release]

  defp release_effect(%{"release" => release}) when is_integer(release),
    do: [release_id: Integer.to_string(release)]

  defp release_effect(_data), do: []

  # `review_approved` and `check_passed` on ONE revision make a change ready, whichever came
  # second. Events apply in `event_seq` order, so every earlier one of this change has applied.
  defp ready_intent(tenant_id, %Event{} = event) do
    cond do
      event.kind == "review_approved" and Map.get(event.data, "by") not in @approvers ->
        {:wait, "unrecognised_approver"}

      superseded_revision?(tenant_id, event) ->
        {:wait, "superseded_revision"}

      earlier_pair?(tenant_id, event) ->
        {:move, :ci, :change_ready, []}

      true ->
        {:wait,
         if(event.kind == "review_approved", do: "awaiting_checks", else: "awaiting_review")}
    end
  end

  defp earlier(tenant_id, %Event{} = event) do
    from e in Event,
      where:
        e.tenant_id == ^tenant_id and e.repo == ^event.repo and e.change_id == ^event.change_id and
          e.event_seq < ^event.event_seq
  end

  defp superseded_revision?(tenant_id, event) do
    tenant_id
    |> earlier(event)
    |> where([e], e.kind == "submitted" and e.revision > ^event.revision)
    |> Repo.exists?()
  end

  defp earlier_pair?(tenant_id, %Event{kind: "check_passed"} = event) do
    tenant_id
    |> earlier(event)
    |> where([e], e.kind == "review_approved" and e.revision == ^event.revision)
    |> where([e], fragment("?->>'by'", e.data) in ^@approvers)
    |> Repo.exists?()
  end

  defp earlier_pair?(tenant_id, %Event{kind: "review_approved"} = event) do
    tenant_id
    |> earlier(event)
    |> where([e], e.kind == "check_passed" and e.revision == ^event.revision)
    |> Repo.exists?()
  end

  # ── making it so ────────────────────────────────────────────────────────────

  defp realise(:unmapped, _tenant_id, _event, _target), do: {%{"outcome" => "unmapped"}, []}

  defp realise({:wait, why}, _tenant_id, _event, _target),
    do: {%{"outcome" => "waiting", "for" => why}, []}

  defp realise({:move, to, edge, effects}, tenant_id, event, %{row: row} = target) do
    cond do
      row.stage == to ->
        {%{"outcome" => "already_there", "at" => Atom.to_string(to)}, []}

      StageMachine.allowed?(row.stage, to, edge) ->
        move(tenant_id, event, target, {row.stage, to, edge}, effects)

      true ->
        outside(tenant_id, event, target, "#{event.kind} moves #{row.stage} nowhere")
    end
  end

  defp realise({:outside, why}, tenant_id, event, target),
    do: outside(tenant_id, event, target, why)

  defp realise({:escalate, edge}, tenant_id, event, target),
    do: escalate(tenant_id, event, target, edge, revert_reason(event))

  defp realise({:trunk_verified, sha}, tenant_id, event, %{story_id: story_id}) do
    case Stages.record_trunk_verified_in_tenant_transaction(tenant_id, story_id, sha,
           actor_label: @actor_label,
           event_data: event_data(event)
         ) do
      {:ok, outcome, _row} ->
        {%{"outcome" => "trunk_verified", "recorded" => Atom.to_string(outcome)}, []}

      {:error, reason} ->
        {%{"outcome" => "refused", "reason" => Atom.to_string(reason)}, []}
    end
  end

  defp realise(:revert_after_done, tenant_id, event, %{story_id: story_id}) do
    history(tenant_id, story_id, "change_reverted_after_done", event)

    {:ok, issue} =
      RevertIssues.record_in(Repo, tenant_id, %{
        story_id: story_id,
        source_id: event.source_id,
        repo: event.repo,
        change_id: event.change_id,
        event_seq: event.event_seq,
        revision: event.revision,
        data: event.data
      })

    {%{"outcome" => "reverted_after_done", "issue" => Atom.to_string(issue)}, []}
  end

  defp move(tenant_id, event, %{story_id: story_id, claim_epoch: epoch}, transition, effects) do
    {_from, to, edge} = transition

    opts =
      control_opts(event, epoch) ++
        [effects: effects, reason: if(edge == :reverted, do: revert_reason(event))]

    case Stages.advance_in_tenant_transaction(tenant_id, story_id, transition, opts) do
      {:ok, _row, entry} ->
        {%{"outcome" => "moved", "to" => Atom.to_string(to), "edge" => Atom.to_string(edge)},
         entries(entry)}

      # Only a refusal decided before the database comes back here (an effect value the
      # machine will not store); the event is recorded with it rather than lost.
      {:error, reason} ->
        {%{"outcome" => "refused", "reason" => Atom.to_string(reason)}, []}
    end
  end

  # An edge the machine does not allow from here: a human decides what the story is now.
  defp outside(tenant_id, event, %{row: %StoryStage{stage: stage}} = target, why) do
    cond do
      stage == :escalated ->
        history(tenant_id, target.story_id, "change_event_outside_lifecycle", event)
        {%{"outcome" => "outside_lifecycle", "at" => "escalated", "escalated" => "already"}, []}

      stage in [:done, :failed] ->
        history(tenant_id, target.story_id, "change_event_outside_lifecycle", event)
        {%{"outcome" => "outside_lifecycle", "at" => Atom.to_string(stage)}, []}

      true ->
        escalate(tenant_id, event, target, :change_outside_lifecycle, outside_reason(event, why))
    end
  end

  defp escalate(tenant_id, event, %{story_id: story_id, claim_epoch: epoch}, edge, reason) do
    opts =
      control_opts(event, epoch) ++
        [edge: edge, reason: reason, payload: event_data(event), in_tenant_transaction: true]

    case Escalations.escalate_as_control(tenant_id, story_id, opts) do
      {:ok, _row, entry} ->
        {%{"outcome" => "escalated", "edge" => Atom.to_string(edge)}, entries(entry)}

      {:error, reason} ->
        {%{"outcome" => "refused", "reason" => inspect(reason)}, []}
    end
  end

  defp entries(nil), do: []
  defp entries(entry), do: [{:entry, entry}]

  defp control_opts(event, epoch) do
    [
      claim_epoch: epoch,
      actor_label: @actor_label,
      actor_role: :agent,
      actor_lineage: [],
      event_data: event_data(event)
    ]
  end

  # Which event decided the move, on the transition's stage event. Every value has a bounded
  # shape (the envelope validated it), so this always fits `Stages.max_event_data_bytes/0`.
  defp event_data(%Event{} = event) do
    %{
      "change_id" => event.change_id,
      "event_seq" => event.event_seq,
      "kind" => event.kind,
      "revision" => event.revision,
      "sha" => event.sha
    }
  end

  defp revert_reason(%Event{data: data} = event) do
    "reverted: chg reverted change #{RevertIssues.safe_id(event.change_id)} revision " <>
      "#{event.revision}, landed as #{RevertIssues.safe_sha(data["landed_sha"])}, by " <>
      "#{RevertIssues.safe_sha(data["revert_sha"])} (chg change " <>
      "#{RevertIssues.safe_id(data["revert_change_id"])}, verification " <>
      "#{RevertIssues.safe_id(data["verification_id"])})"
  end

  defp outside_reason(%Event{} = event, why) do
    "change_outside_lifecycle: #{why} (chg change #{RevertIssues.safe_id(event.change_id)} " <>
      "event #{event.event_seq}, revision #{event.revision}). Trunk may hold a change this " <>
      "story did not expect; a human decides what the story is now."
  end

  # The story's own history (`GET /stories/:id/history` reads `audit_log`), in this
  # transaction, for a change event that reached a story nothing here may move.
  defp history(tenant_id, story_id, action, %Event{} = event) do
    {:ok, _entry} =
      Audit.create_log_entry(
        tenant_id,
        %{
          entity_type: "story",
          entity_id: story_id,
          action: action,
          actor_type: "system",
          actor_label: @actor_label,
          metadata: Map.put(event_data(event), "data", Map.take(event.data, @history_keys))
        },
        Repo
      )

    :ok
  end
end
