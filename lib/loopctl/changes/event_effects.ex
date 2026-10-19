defmodule Loopctl.Changes.EventEffects do
  @moduledoc """
  What applying ONE chg event does to loopctl's state — the single seam event application goes
  through (Epic 47 PRD §5).

  `Loopctl.Changes.Events` calls `apply_event/2` once per event, in `event_seq` order, inside
  the transaction that holds the change's cursor lock and that records the event as applied
  and appends it to the audit chain. Whatever this returns is stored on the event row as its
  `effect`; a value returned here is never a reason to leave the event unapplied, because an
  unapplied event would hold every later one behind a gap that never fills.

  ## What US-47.3 applies

  - `submitted` with a `data.story_id` binds the change to that story
    (`Loopctl.Changes.bind_in_tenant_transaction/3`, PRD §4). The submitter is the webhook,
    a machine caller with no agent and no lineage, so a binding it makes is always
    `submitter_not_claimant` and never touches custody. A refusal (the change bound to
    another story, or superseded) is recorded as the effect, not raised. `story_id: null`
    binds nothing.
  - Every other kind is recorded and moves nothing.

  ## What US-47.4 adds here

  The stage mapping (PRD §5's table): each mapped kind moves the bound story's stage over its
  edge, and an unmapped kind (`review_requested`, `check_failed`, `conflict`, `ready`, or any
  kind chg adds later) stays a recorded no-op (AC-47.3.6). That story fills this module; the
  ordering, idempotency and audit around it do not change.

  ## Return

  `{:ok, effect, pending}`: `effect` is a JSON-safe map stored on the event; `pending` is a
  list of things to finish after commit (`after_commit/1`).
  """

  alias Loopctl.Changes
  alias Loopctl.Changes.Binding
  alias Loopctl.Changes.Event

  # The webhook is a machine caller: no API key, so no agent and no lineage (PRD §5). It can
  # bind a change, which is informational, and can never perform a custody act.
  @machine_submitter %{agent_id: nil, actor_lineage: []}

  @type pending :: [{:bind, Changes.pending_bind()}]

  @doc "Applies `event` for `tenant_id`, inside the caller's tenant transaction."
  @spec apply_event(Ecto.UUID.t(), Event.t()) :: {:ok, map(), pending()}
  def apply_event(tenant_id, %Event{kind: "submitted"} = event) do
    case Map.get(event.data, "story_id") do
      nil ->
        {:ok, %{"effect" => "recorded", "binding" => "no_story"}, []}

      story_id ->
        bind(tenant_id, event, story_id)
    end
  end

  def apply_event(_tenant_id, %Event{}), do: {:ok, %{"effect" => "recorded"}, []}

  @doc "Finishes what `apply_event/2` left pending, after the caller's transaction commits."
  @spec after_commit(pending()) :: :ok
  def after_commit(pending) do
    Enum.each(pending, fn {:bind, bind} -> Changes.after_bind_commit(bind) end)
  end

  defp bind(tenant_id, event, story_id) do
    {:ok, {outcome, _tenant_id, _input} = pending} =
      Changes.bind_in_tenant_transaction(
        tenant_id,
        %{story_id: story_id, repo: event.repo, change_id: event.change_id},
        @machine_submitter
      )

    {:ok, Map.put(%{"effect" => "recorded"}, "binding", describe(outcome)), [{:bind, pending}]}
  end

  defp describe({:bound, %Binding{id: id}, _entry}), do: %{"outcome" => "bound", "id" => id}
  defp describe({:existing, %Binding{id: id}}), do: %{"outcome" => "existing", "id" => id}
  defp describe({:unbound, _entry}), do: %{"outcome" => "unbound"}

  defp describe({:refused, %Ecto.Changeset{}}),
    do: %{"outcome" => "refused", "reason" => "invalid_story_id"}

  defp describe({:refused, reason}) when is_atom(reason),
    do: %{"outcome" => "refused", "reason" => Atom.to_string(reason)}
end
