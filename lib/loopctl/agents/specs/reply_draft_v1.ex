defmodule Loopctl.Agents.Specs.ReplyDraftV1 do
  @moduledoc """
  `reply_draft@1`, a `:draft`: drafts a reply to a support ticket triage set aside (US-48.9).

  The first spec that is not a transcription of an existing kind, and the smallest custody
  surface the registry has: it CLAIMS NOTHING (the dispatch echoes the story's current
  `claim_epoch`, as triage's does), BINDS NOTHING, writes no repository (its runner template is
  read-only) and names NO stage edge — every route below is `[]`. What it produces is a
  `reply_drafts` row a person reads and sends; loopctl never sends it (Epic 48 PRD, default 2).

  - **Candidates** — a story triage SET ASIDE (`:triage_set_aside`: its latest transition is
    `triaged -> failed` on `:triage_reject` or `triaged -> escalated` on `:triage_escalate`),
    filed from an intake record carrying a support `ticket_id` (`:ticket_required`), on a
    project bound to one source (the repository the session reads), with no live dispatch of
    this kind and no `reply_drafts` row yet (`:no_reply_draft`, drafted or refused).
    `:issue_not_closed` is deliberately absent: a rejected ticket's issue is often closed, and
    the customer is still owed an answer. Overrule the set in this list (PRD default 3).
  - **Payload** — `:fenced_intake_report`, triage's own: the reporter's words fenced by
    `TriagePayload.build/1`, riding the dispatch's `triage` object (contract 1.26.0 lets it
    ride a `reply_draft` dispatch). The refs are the source's base branch for both fields, as
    for triage: the session reads the repository and commits nothing.
  - **Budgets** — the TRIAGE pair (`TRIAGE_WALL_CLOCK_SECONDS`, `TRIAGE_MAX_TURNS`): a drafter
    is a reading session the size of a triage run, and a separate pair would be a second
    figure for an operator to set before the first draft could go out.
  - **Result** — the generic `agent_result`, validated against `result_schema`: an object
    with exactly one field, `body`, the drafted reply.
  - **Screens** — `:payload_too_large` (a ticket `TriagePayload` refuses whole) and
    `:injection_detector_draft` (`Loopctl.ReplyDrafts.screen/1`, the drafted-story screen's
    detector and signal set). Each stores a REFUSED row with the screen's name, no body, and
    moves nothing.
  - **Effect** — `:reply_draft`, the row `Loopctl.ReplyDrafts.write_result/2` writes in the
    ledger's own transaction.

  ## Why `body` is at most 3_000 characters

  The result rides `agent_result`, whose envelope caps `result` at
  `RunnerAgentResultMessage.max_result_bytes/0` (48_000) under the byte rule. One character of
  `maxLength` is one grapheme, which is at most 12 bytes under the rule when it is a single
  code point outside the Basic Multilingual Plane, and the object around it costs 52; so
  3_000 is the round figure whose worst single-code-point case (36_052) stays under the
  envelope with room to spare, and the schema's own bound is the one a session meets first.
  A grapheme built from several code points can still exceed the envelope; that is refused
  `invalid_payload` by the envelope cast before any schema runs. 3_000 characters is a long
  support reply — roughly 500 words — and a draft longer than that is one a person should
  write.
  """

  @max_body_length 3_000

  @doc "The longest `body` the result schema admits, in characters."
  @spec max_body_length() :: pos_integer()
  def max_body_length, do: @max_body_length

  use Loopctl.Agents.Spec,
    id: "reply_draft",
    version: 1,
    archetype: :draft,
    kind: "reply_draft",
    candidates: %{
      predicates: [
        :triage_set_aside,
        :intake_record_required,
        :ticket_required,
        :single_active_source,
        :no_live_dispatch_of_self,
        :no_reply_draft
      ],
      order: :round_robin_project_tenant
    },
    sweeps: %{},
    payload: :fenced_intake_report,
    refs: [branch: :source_base_branch, base_branch: :source_base_branch],
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
      required: [:body],
      additionalProperties: false,
      properties: %{
        body: %OpenApiSpex.Schema{
          type: :string,
          minLength: 1,
          maxLength: @max_body_length,
          pattern: "\\S",
          description:
            "The drafted reply to the customer, as plain text. A person reads it and sends " <>
              "it; loopctl never does."
        }
      }
    },
    screens: %{payload_too_large: [], injection_detector_draft: []},
    outcomes: %{"draft" => []},
    effects: [:reply_draft],
    rerun: :next_pass,
    concurrency: :one_unreleased_dispatch_per_story,
    prompt: {"reply_draft", 1}
end
