defmodule Loopctl.Repo.Migrations.AddStoryStagesTriageDispatchId do
  @moduledoc """
  Which triage dispatch decides a story (epic 44, US-44.1). A stage-row identity recorded by
  `Loopctl.Delivery.Stages.record_effect/5` at `detected`, before the verdict is stored, so a
  second dispatch's verdict is refused and the merge gate's Gate A reads exactly this
  dispatch's lens verdicts. No backfill and no manual step: NULL on every existing row, which
  Gate A reads as "no triage verdict" and refuses.

  No foreign key, for the reason `triage_verdicts.dispatch_id` has none: the record of what
  triage decided must outlive the dispatch, which is pruned.
  """

  use Ecto.Migration

  def change do
    alter table(:story_stages) do
      add :triage_dispatch_id, :binary_id
    end
  end
end
