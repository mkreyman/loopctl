defmodule Loopctl.Repo.Migrations.AddStoryStagesTriageDispatchId do
  @moduledoc """
  Which triage dispatch decided a story (epic 44, US-44.1). A stage-row identity carried ON the
  `detected -> triaged` transition by the dispatch whose verdict took it, in that transition's
  transaction, so the merge gate's Gate A reads exactly this dispatch's lens verdicts and any
  other dispatch is refused before it can move the story further. No backfill and no manual step: NULL on every existing row, which
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
