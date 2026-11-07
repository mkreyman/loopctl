defmodule Loopctl.Agents.Specs.TriageV1 do
  @moduledoc """
  `triage@1`, a `:judge`: today's triage dispatch, transcribed (US-48.2).

  The DISPATCH half is read: `Loopctl.Agents.Dispatcher.run/2` runs the pass from `candidates`
  (US-48.3), `payload`, `refs`, `budgets`, `kind`, `sweeps` and the `:payload_too_large` screen
  (US-48.4). The RESULT half is read too: `Loopctl.Delivery.TriageVerdict.apply/4` routes each
  outcome by `outcomes`, takes each verdict screen's route from `screens` and applies `effects`
  by name (US-48.5).

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
        {:stage, :detected},
        :intake_record_required,
        :single_active_source,
        :no_live_dispatch_of_self,
        :requires_ticket_if_source_says,
        :issue_not_closed
      ],
      order: :round_robin_project_tenant
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
