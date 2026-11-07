defmodule Loopctl.Agents.Specs.VerifyV1 do
  @moduledoc """
  `verify@1`, a `:judge`: a second runner session judges a pull-request-route story at `ci`
  against its acceptance criteria, and CONTROL reports, reviews and verifies it on that verdict
  under a verifier dispatch rooted apart from the implementer's (US-48.18).

  Without it the pr route has no custody act after the claim: `start`, `report`,
  `review-complete` and `verify` are never called, so `Progress.merge_custody_status/1` is
  never `:ok` and the merge gate refuses every story.

  - **Candidates** — a story at `ci` (`{:stage, :ci}`), on a project bound to one source
    (`:single_active_source`) in mode `pr` (`:pr_route_source`), whose stage row records a head
    with no verification AT that head (`:head_unverified`, the complement of the merge job's
    read), that names an implementer dispatch and agent to be separated from
    (`:implementer_dispatched`), still claimed (`agent_status` `:assigned`, `:implementing` or
    `:reported_done` — `:assigned` is a story claimed before its start was spent, which
    `Loopctl.Delivery.ImplementerStart` starts before the verdict reports it), with no live
    `verify` ledger row and no verifier dispatch in flight (`:no_live_dispatch_of_self`,
    `:no_live_verifier_dispatch`).
  - **Placement** — `Loopctl.Agents.VerifierPlacement`, not a stock `:judge` push: it mints the
    verifier dispatch B under the tenant's operator key as a NEW ROOT, role `:orchestrator`, for
    a runner whose agent is not the implementer's, and binds it through
    `Progress.bind_verifier_dispatch/4`. B's key never leaves loopctl: the dispatch the runner is
    sent carries no credential, and its `dispatch_id` IS B's id, which is how a verdict is
    matched to B.
  - **Payload** — `:verify_payload`: the story object (`RunnerStory`, as an implement dispatch
    carries) plus `verify` (`RunnerVerify`: the pull request and the head, off the stage row).
    `branch` is the stage row's branch (`:stage_branch`), the pull request's own, which the
    session reads and never writes; `base_branch` is the source's.
  - **Budgets** — the TRIAGE pair, as `reply_draft@1` uses: a verifier is a reading session.
  - **Result** — the generic `agent_result`: `{verdict, head_sha, findings}`.
  - **Outcomes** — `pass` moves no stage: control reports, reviews and verifies, then records
    `verified_head_sha`. `reject` sends the story back to work over the control-only
    `:verify_rejected`, the findings as its reason.
  - **Screens** — `:verdict_stale` (a verdict for a head that is no longer the story's, or a
    story no longer at `ci`: dropped and recorded, moving nothing) and
    `:no_independent_verifier_runner` (only the implementer's own agent could take it: the
    story escalates for a person to add a machine).
  - **Effects** — `:verify_verdict` (the `Loopctl.Workers.VerifyVerdictWorker` job, enqueued
    once the ledger write commits, that applies the verdict through
    `Loopctl.Agents.VerifyVerdict`) and `:verified_head_sha`.

  ## Why `findings` is ten strings of at most 300 characters

  They become the `:verify_rejected` reason, which is bounded by
  `StageMachine.max_reason_length/0` (4 000 codepoints). Ten of 300 plus separators stay well
  under it, and under the `agent_result` envelope's 48 000 bytes at twelve bytes a character.
  """

  @max_findings 10
  @max_finding_length 300

  @doc "The most findings a verdict may carry."
  @spec max_findings() :: pos_integer()
  def max_findings, do: @max_findings

  @doc "The longest finding, in characters."
  @spec max_finding_length() :: pos_integer()
  def max_finding_length, do: @max_finding_length

  use Loopctl.Agents.Spec,
    id: "verify",
    version: 1,
    archetype: :judge,
    kind: "verify",
    candidates: %{
      predicates: [
        {:stage, :ci},
        :single_active_source,
        :pr_route_source,
        :head_unverified,
        :implementer_dispatched,
        {:agent_status_in, [:assigned, :implementing, :reported_done]},
        :no_live_dispatch_of_self,
        :no_live_verifier_dispatch
      ],
      order: :round_robin_project_tenant
    },
    sweeps: %{},
    payload: :verify_payload,
    refs: [branch: :stage_branch, base_branch: :source_base_branch],
    runner: [
      :connected,
      :not_draining,
      :repo_declared,
      :kind_declared,
      :free_slot,
      :subscription_not_exhausted
    ],
    advance_on: [],
    budgets: {:triage_wall_clock_seconds, :triage_max_turns},
    result: ["agent_result"],
    result_schema: %OpenApiSpex.Schema{
      type: :object,
      required: [:verdict, :head_sha, :findings],
      additionalProperties: false,
      properties: %{
        verdict: %OpenApiSpex.Schema{
          type: :string,
          enum: ["pass", "reject"],
          description:
            "`pass` when the pull request at `head_sha` meets every acceptance criterion, " <>
              "`reject` otherwise."
        },
        head_sha: %OpenApiSpex.Schema{
          type: :string,
          pattern: "^[0-9a-f]{40}([0-9a-f]{24})?$",
          description:
            "The head the session judged: the dispatch's `verify.head_sha`. A verdict for " <>
              "any other head is dropped."
        },
        findings: %OpenApiSpex.Schema{
          type: :array,
          maxItems: @max_findings,
          items: %OpenApiSpex.Schema{
            type: :string,
            minLength: 1,
            maxLength: @max_finding_length,
            pattern: "\\S"
          },
          description:
            "What fails, one finding per entry; empty on a `pass`. On a `reject` they are " <>
              "the reason the story goes back to work."
        }
      }
    },
    screens: %{
      verdict_stale: [],
      no_independent_verifier_runner: [{:ci, :escalated, :no_independent_verifier_runner}]
    },
    outcomes: %{"pass" => [], "reject" => [{:ci, :implementing, :verify_rejected}]},
    effects: [:verify_verdict, :verified_head_sha],
    rerun: :next_pass,
    concurrency: :one_unreleased_dispatch_per_story,
    prompt: {"verify", 1}
end
