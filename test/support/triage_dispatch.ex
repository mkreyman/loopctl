defmodule Loopctl.Test.TriageDispatch do
  @moduledoc """
  The stage moves a `Loopctl.Delivery.TriageDispatcher` test makes before a pass.

  Shared by `Loopctl.Delivery.TriageDispatcherTest` (sandboxed) and
  `Loopctl.Delivery.TriageDispatcherFaultTest` (committed, for a fault injected with DDL).
  The story they start from is `fixture(:detected_story)`.
  """

  alias Loopctl.Delivery.Stages

  @doc """
  The FIRST half of the too-large route alone: `triaged`, nothing bound, no verdict — a row
  the dispatcher's stranded sweep finishes.
  """
  def half_take(tenant_id, story) do
    row = Stages.get(tenant_id, story.id)

    {:ok, _row} =
      Stages.advance(tenant_id, story.id, {:detected, :triaged, :forward},
        claim_epoch: row.claim_epoch,
        actor_label: "worker:triage_dispatcher",
        actor_role: :agent,
        actor_lineage: []
      )
  end
end
