defmodule Loopctl.Agents.Specs.TriageV1 do
  @moduledoc """
  `triage@1`, a `:judge`: today's triage dispatch, transcribed (US-48.2).

  Nothing in `lib/` reads this yet. The behaviour lives in `Loopctl.Delivery.TriageDispatcher`
  (candidates, the stranded sweep, the payload, the budgets) and `Loopctl.Delivery.TriageVerdict`
  (routes, screens, the draft); `Loopctl.Agents.RegistryTest` holds the two equal until later
  stories move the behaviour onto this description.

  - **Claims nothing.** The dispatch echoes the story's current `claim_epoch`.
  - **Every outcome passes through `triaged` first**, and the transition out of it is
    control's conclusion from the verdict, never a runner's `stage` report: every route here
    is control-only, which is what the `:judge` archetype requires.
  - **`incomplete`** is the `triage_verdict` message's other branch: every incomplete reason
    escalates, exactly as `escalate` does.
  - **Screens** only ever ADD an escalation. The too-large route escalates from `detected`
    through `triaged`; the verdict screens replace the `story` route's `triaged -> queued`.
  """

  use Loopctl.Agents.Spec,
    id: "triage",
    version: 1,
    archetype: :judge,
    kind: "triage",
    candidates: %{
      predicates: [
        :stage_detected,
        :from_intake_record,
        :one_active_intake_source,
        :no_unreleased_dispatch_of_kind,
        :ticket_when_source_requires,
        :issue_not_closed
      ],
      order: :oldest_per_project_round_robin_projects_then_tenants
    },
    sweeps: %{
      stranded_triaged_unbound: [
        {:detected, :triaged, :forward},
        {:triaged, :escalated, :triage_escalate}
      ]
    },
    payload: :triage_payload,
    refs: [branch: :source_base_branch, base_branch: :source_base_branch],
    runner: [
      :connected,
      :not_draining,
      :repo_declared,
      :kind_declared,
      :free_slot,
      :subscription_not_exhausted
    ],
    budgets: {:triage_wall_clock_seconds, :triage_max_turns},
    result: ["triage_verdict"],
    screens: %{
      payload_too_large: [
        {:detected, :triaged, :forward},
        {:triaged, :escalated, :triage_escalate}
      ],
      gate_a: [{:triaged, :escalated, :triage_escalate}],
      gate_b: [{:triaged, :escalated, :triage_escalate}],
      draft_injection: [{:triaged, :escalated, :triage_escalate}],
      draft_dispatchable: [{:triaged, :escalated, :triage_escalate}]
    },
    outcomes: %{
      "story" => [{:detected, :triaged, :forward}, {:triaged, :queued, :forward}],
      "escalate" => [{:detected, :triaged, :forward}, {:triaged, :escalated, :triage_escalate}],
      "reject" => [{:detected, :triaged, :forward}, {:triaged, :failed, :triage_reject}],
      "incomplete" => [
        {:detected, :triaged, :forward},
        {:triaged, :escalated, :triage_escalate}
      ]
    },
    effects: [:triage_dispatch_id, :story_draft],
    rerun: :next_pass,
    concurrency: :one_unreleased_dispatch_per_story,
    prompt: {"triage", 1}
end
