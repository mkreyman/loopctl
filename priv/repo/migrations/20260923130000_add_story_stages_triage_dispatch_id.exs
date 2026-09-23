defmodule Loopctl.Repo.Migrations.AddStoryStagesTriageDispatchId do
  @moduledoc """
  Which triage dispatch decided a story (epic 44, US-44.1). A stage-row identity carried ON the
  `detected -> triaged` transition by the dispatch whose verdict took it, in that transition's
  transaction, so the merge gate's Gate A reads exactly this dispatch's lens verdicts and any
  other dispatch is refused before it can move the story further.

  No foreign key, for the reason `triage_verdicts.dispatch_id` has none: the record of what
  triage decided must outlive the dispatch, which is pruned.

  ## The backfill, and the rows it deliberately leaves NULL

  A row triaged before this column existed would otherwise never finish: every transition out
  of `triaged` names a session dispatch, `Stages.advance/4` refuses one that is not bound, and a
  resend of the verdict that triaged it is refused the same way. So a row PAST `detected` whose
  story has EXACTLY ONE recorded triage verdict is bound to that verdict's dispatch — the only
  dispatch that can have taken it out of `detected` by verdict. No manual step.

  Two kinds of row stay NULL, on purpose:

  - A story with SEVERAL recorded verdicts. Which one decided it is not in the data, and a
    guess would hand Gate A the lens verdicts of a dispatch that may have lost. Unbound, the
    merge gate reads no triage (`:missing`) and escalates, which is the safe state.
  - A story with NONE — which includes every row `Loopctl.Delivery.TriageDispatcher`'s
    too-large route took to `triaged`. That route is control's, not a session's: it names no
    session dispatch, so the binding never blocked it, and no verdict decided the story, so
    there is no dispatch whose authority a backfill could honestly record. Binding it to
    anything would grant a dispatch a decision it never made. What strands such a row at
    `triaged` is the route's own second transaction failing, which the dispatcher documents,
    not this column.
  """

  use Ecto.Migration

  def up do
    alter table(:story_stages) do
      add :triage_dispatch_id, :binary_id
    end

    flush()

    execute("""
    UPDATE story_stages AS s
       SET triage_dispatch_id = v.dispatch_id
      FROM (SELECT tenant_id, story_id, (array_agg(dispatch_id))[1] AS dispatch_id
              FROM triage_verdicts
             GROUP BY tenant_id, story_id
            HAVING count(*) = 1) AS v
     WHERE s.tenant_id = v.tenant_id
       AND s.story_id = v.story_id
       AND s.stage <> 'detected'
       AND s.triage_dispatch_id IS NULL
    """)
  end

  def down do
    alter table(:story_stages) do
      remove :triage_dispatch_id
    end
  end
end
