defmodule Loopctl.Agents.Specs.ImplementV1 do
  @moduledoc """
  `implement@1`, a `:build`: today's implement dispatch, transcribed (US-48.2).

  The DISPATCH half is read: `Loopctl.Agents.Dispatcher.run/2` runs the `:build` pass from
  `candidates` (US-48.3), `kind`, `payload`, `refs`, `runner`, `advance_on` and `budgets`
  (US-48.7), and `Loopctl.Delivery.DispatchDriver` is a wrapper over it. The RESULT half
  (`outcomes`, `screens`, `effects`) still lives in `Loopctl.Delivery.RunnerStages` and
  `Loopctl.Delivery.StoryPayload`; `Loopctl.Agents.RegistryTest` holds the two equal.

  - **Claims the story and mints a session dispatch**, binding `implementer_dispatch_id`. That
    is archetype semantics and stays code (`Placement.place/4`, which the pass CALLS and which
    refuses any kind whose spec is not a `:build`): the claim's `queued -> claimed` is
    control's, so this spec does not name it.
  - **`payload: :story_payload`** — the pass sends no story object: `Placement.place/4` builds
    it from loopctl's own rows after the claim (`StoryPayload.build/3`) and refuses one a
    caller supplies.
  - **`refs`** — `branch` is DERIVED per story from the target runner's declared prefixes
    (`DispatchPayload.fill/3`, inside `place/4`), so the pass omits it; `base_branch` is the
    intake source's, judged by the same `fill/3` before anything is minted.
  - **`runner`** names `:tenant_admission_headroom`, which is the pass's
    `Loopctl.Runners.Capacity.admit/2` pre-check; `advance_on` is the two machine refusals on
    which the pass tries the story's next runner.
  - **`stage`** may carry exactly the runner-reportable transitions
    (`StageMachine.runner_transitions/0`), one per message, and the reportable effects with
    them. Listed here rather than read, so the registry test is a real comparison.
  - **`session_ended`** is a FACT the runner reports; what it does to the story
    (`:budget_reported`, a release over `:runner_lost`) is control's decision in
    `Loopctl.Delivery.RunnerStages.end_session/4`, archetype semantics again, so no
    control-only edge is named here.
  - **The one screen** is `StoryPayload`'s park of a story the contract cannot describe, over
    the session's own escalation edge from `claimed`.
  """

  use Loopctl.Agents.Spec,
    id: "implement",
    version: 1,
    archetype: :build,
    kind: "implement",
    candidates: %{
      predicates: [
        {:stage, :queued},
        {:agent_status_in, [:pending, :contracted]},
        :dependencies_met,
        :single_active_source,
        :intake_record_optional,
        :issue_not_closed
      ],
      order: :round_robin_project_tenant
    },
    sweeps: %{},
    payload: :story_payload,
    refs: [branch: :story_branch_for_runner_prefixes, base_branch: :source_base_branch],
    runner: [
      :connected,
      :not_draining,
      :repo_declared,
      :kind_declared,
      :free_slot,
      :subscription_not_exhausted,
      :tenant_admission_headroom
    ],
    advance_on: [:runner_exhausted, :no_conforming_branch],
    budgets: {:dispatch_wall_clock_seconds, :dispatch_max_turns},
    result: ["stage", "session_ended"],
    # A `:build` answers with `stage` and `session_ended`, never the generic `agent_result`.
    result_schema: nil,
    screens: %{
      story_not_dispatchable: [{:claimed, :escalated, :session_escalated}]
    },
    outcomes: %{
      "stage" => [
        {:claimed, :worktree, :forward},
        {:worktree, :implementing, :forward},
        {:implementing, :reviewing, :forward},
        {:reviewing, :pr_open, :forward},
        {:pr_open, :ci, :forward},
        {:ci, :merged, :forward},
        {:merged, :deployed, :forward},
        {:ci, :implementing, :ci_red},
        {:reviewing, :implementing, :review_findings},
        {:pr_open, :implementing, :base_moved},
        {:ci, :implementing, :base_moved},
        {:merged, :implementing, :merge_refused},
        {:claimed, :escalated, :session_escalated},
        {:worktree, :escalated, :session_escalated},
        {:implementing, :escalated, :session_escalated},
        {:reviewing, :escalated, :session_escalated},
        {:pr_open, :escalated, :session_escalated},
        {:ci, :escalated, :session_escalated},
        {:merged, :escalated, :session_escalated}
      ]
    },
    effects: [:branch, :head_sha, :merge_sha, :pr_number, :release_id, :worktree_path],
    rerun: :requeue_until_retry_ceiling,
    concurrency: :one_claim_per_story,
    prompt: {"implement", 1}
end
