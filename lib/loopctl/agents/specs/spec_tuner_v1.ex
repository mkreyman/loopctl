defmodule Loopctl.Agents.Specs.SpecTunerV1 do
  @moduledoc """
  `spec_tuner@1`, a `:draft`: proposes a better prompt template for ANOTHER spec, from the runs
  of it that failed, and the eval cases that would have caught them (US-48.13).

  The improvement loop. It CLAIMS NOTHING and has NO STORY — its subject is a (project, target
  spec) pair, picked by `Loopctl.Agents.Tuning.candidates/1` — names NO stage edge, and changes
  nothing it proposes: loopctl stores the proposal as a `spec_tuning_drafts` row and a person
  turns it into a pull request. Neither the template nor any spec version is ever written by
  loopctl (AC-48.13.4; `test/loopctl/agents/tuning_no_self_edit_test.exs`).

  - **Candidates** — `%{subject: :spec_outcomes}`: a (tenant, project, target spec) with at
    least `min_outcome_rows/0` outcome rows (US-48.12) since its last answered tuning run, no
    pending run, and one active intake source (the repository the session reads).
  - **Payload** — `:spec_tune_traces` (`Loopctl.Agents.Tuning.input/3`): the target's FAILED
    runs as trace entries — loopctl's own failure codes and decisions, and the story's text
    rendered by `Loopctl.Delivery.Untrusted.render/2`, the fence triage uses — with the
    target's template `{id, version}` and eval-set identity. The runner assembles the prompt.
  - **Budgets** — its own pair, `SPEC_TUNE_WALL_CLOCK_SECONDS` / `SPEC_TUNE_MAX_TURNS`: the
    runner bounds a tuning run by this wall clock, and the critic runs every eval case under
    both the current and the proposed template, each with that case's whole wall clock, so a
    triage-sized budget can never hold it. Unset, no tuning run is dispatched.
  - **Result** — the generic `agent_result` against `result_schema` below: new cases, the
    proposed template diff, and the eval scores of current and proposed templates per case.
  - **Effect** — `:tuning_draft`: `Loopctl.Agents.Tuning.write_result/2` answers the pending
    row in the ledger's own transaction. The STATUS is loopctl's (`Tuning.decide/2`), recomputed
    from the per-case results; the runner's own scores are evidence, never the verdict.

  ## Why a new case carries no `input`

  Each new case names the trace it came from (`source_trace_id`), and the case's input is that
  trace as loopctl sent it and stored it on the draft. A runner-supplied input would let the
  session write the case it is then scored on; and a triage dispatch alone may reach 48_000
  bytes, the whole envelope.

  ## Bounds

  The envelope caps `result` at `RunnerAgentResultMessage.max_result_bytes/0` (48_000) under the
  byte rule, and that is what binds a result at several fields' maxima at once; each field's own
  bound is the one a session meets first.
  """

  @min_outcome_rows 20
  @max_new_cases 5
  @max_per_case 100
  @max_diff_length 4_000
  @review_findings_high 3

  @doc """
  The outcome rows a target spec must have gained since its last answered tuning run before
  another run is dispatched. A DEFAULT for the operator to overrule here: 20 runs is enough to
  hold a few failures, few enough that a weekly pass reaches a quiet spec within a month.
  """
  @spec min_outcome_rows() :: pos_integer()
  def min_outcome_rows, do: @min_outcome_rows

  @doc "The most new eval cases one result may propose."
  @spec max_new_cases() :: pos_integer()
  def max_new_cases, do: @max_new_cases

  @doc "The most per-case score lines one result may carry."
  @spec max_per_case() :: pos_integer()
  def max_per_case, do: @max_per_case

  @doc "The longest proposed template diff, in characters."
  @spec max_diff_length() :: pos_integer()
  def max_diff_length, do: @max_diff_length

  @doc """
  The review findings at or above which a build run's review counts as a failure. A DEFAULT:
  `review_records` holds no severity, so the count is the only signal.
  """
  @spec review_findings_high() :: pos_integer()
  def review_findings_high, do: @review_findings_high

  alias OpenApiSpex.Schema

  @name_pattern "^[a-z0-9][a-z0-9_]{0,63}$"
  @code_pattern "^[a-z][a-z0-9_]{0,63}$"

  # One template's eval score, the runner's count: evidence `Tuning.decide/2` recomputes.
  @score_schema %Schema{
    type: :object,
    required: [:passed, :total],
    additionalProperties: false,
    properties: %{
      passed: %Schema{type: :integer, minimum: 0, maximum: @max_per_case},
      total: %Schema{type: :integer, minimum: 0, maximum: @max_per_case}
    }
  }

  use Loopctl.Agents.Spec,
    id: "spec_tuner",
    version: 1,
    archetype: :draft,
    kind: "spec_tune",
    candidates: %{subject: :spec_outcomes, order: :round_robin_project_tenant},
    sweeps: %{},
    payload: :spec_tune_traces,
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
    budgets: {:spec_tune_wall_clock_seconds, :spec_tune_max_turns},
    result: ["agent_result"],
    result_schema: %Schema{
      type: :object,
      required: [:new_cases, :proposed_template, :scores],
      additionalProperties: false,
      properties: %{
        new_cases: %Schema{
          type: :array,
          maxItems: @max_new_cases,
          description:
            "The eval cases the proposal adds, one per trace it learned from, in the runner's " <>
              "eval case format minus `input`: the case's input is the named trace.",
          items: %Schema{
            type: :object,
            required: [:name, :source_trace_id, :description, :fixture, :expectations],
            additionalProperties: false,
            properties: %{
              name: %Schema{type: :string, pattern: @name_pattern, maxLength: 64},
              source_trace_id: %Schema{type: :string, format: :uuid},
              description: %Schema{type: :string, minLength: 1, maxLength: 300},
              fixture: %Schema{
                type: :object,
                required: [:repo, :commit],
                additionalProperties: false,
                properties: %{
                  repo: %Schema{type: :string, minLength: 1, maxLength: 200},
                  commit: %Schema{type: :string, pattern: "^[0-9a-f]{40}$"}
                }
              },
              expectations: %Schema{
                type: :object,
                required: [
                  :schema_valid,
                  :outcomes_allowed,
                  :escalation_codes,
                  :lens_agreement,
                  :forbidden,
                  :screens,
                  :rubric
                ],
                additionalProperties: false,
                properties: %{
                  schema_valid: %Schema{type: :boolean},
                  outcomes_allowed: %Schema{
                    type: :array,
                    minItems: 1,
                    maxItems: 8,
                    items: %Schema{type: :string, pattern: @code_pattern, maxLength: 32}
                  },
                  escalation_codes: %Schema{
                    type: :array,
                    maxItems: 10,
                    items: %Schema{type: :string, pattern: @code_pattern, maxLength: 64}
                  },
                  lens_agreement: %Schema{type: :boolean, nullable: true},
                  forbidden: %Schema{
                    type: :array,
                    maxItems: 10,
                    items: %Schema{type: :string, minLength: 1, maxLength: 80}
                  },
                  screens: %Schema{
                    type: :array,
                    maxItems: 10,
                    items: %Schema{type: :string, pattern: @code_pattern, maxLength: 64}
                  },
                  rubric: %Schema{type: :string, nullable: true, maxLength: 500}
                }
              }
            }
          }
        },
        proposed_template: %Schema{
          type: :object,
          required: [:id, :from_version, :to_version, :diff],
          additionalProperties: false,
          properties: %{
            id: %Schema{type: :string, pattern: @code_pattern, maxLength: 64},
            from_version: %Schema{type: :integer, minimum: 1, maximum: 1_000_000},
            to_version: %Schema{type: :integer, minimum: 2, maximum: 1_000_001},
            diff: %Schema{
              type: :string,
              minLength: 1,
              maxLength: @max_diff_length,
              pattern: "\\S",
              description:
                "A unified diff of the template, for a person to read and apply in a pull " <>
                  "request. loopctl never applies it."
            }
          }
        },
        scores: %Schema{
          type: :object,
          required: [:current, :proposed, :per_case],
          additionalProperties: false,
          properties: %{
            current: @score_schema,
            proposed: @score_schema,
            per_case: %Schema{
              type: :array,
              maxItems: @max_per_case,
              description:
                "One line per case the harness ran: whether it is an EXISTING case of the " <>
                  "eval set or one this result adds, and whether it passed under each template.",
              items: %Schema{
                type: :object,
                required: [:case, :existing, :current, :proposed],
                additionalProperties: false,
                properties: %{
                  case: %Schema{type: :string, minLength: 1, maxLength: 96},
                  existing: %Schema{type: :boolean},
                  current: %Schema{type: :boolean},
                  proposed: %Schema{type: :boolean}
                }
              }
            }
          }
        }
      }
    },
    screens: %{},
    outcomes: %{"proposal" => []},
    effects: [:tuning_draft],
    rerun: :next_pass,
    concurrency: :one_pending_tuning_per_project_spec,
    prompt: {"spec_tuner", 1}
end
