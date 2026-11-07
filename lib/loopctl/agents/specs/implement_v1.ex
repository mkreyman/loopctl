defmodule Loopctl.Agents.Specs.ImplementV1 do
  @moduledoc """
  `implement@1`, a `:build`: today's implement dispatch, transcribed (US-48.2).

  Nothing in `lib/` reads this yet. The behaviour lives in `Loopctl.Delivery.DispatchDriver`
  (candidates, eligibility, budgets) and `Loopctl.Delivery.Placement` (the claim, the session
  dispatch, the payload); `Loopctl.Agents.RegistryTest` holds the two equal until later stories
  move the behaviour onto this description.

  - **Claims the story and mints a session dispatch**, binding `implementer_dispatch_id`. That
    is archetype semantics and stays code (`Placement.place/4`): the claim's
    `queued -> claimed` is control's, so this spec does not name it.
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
        :stage_queued,
        :agent_status_pending_or_contracted,
        :dependencies_met,
        :one_active_intake_source,
        :issue_not_closed
      ],
      order: :oldest_per_project_round_robin_projects_then_tenants
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
    budgets: {:dispatch_wall_clock_seconds, :dispatch_max_turns},
    result: ["stage", "session_ended"],
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
