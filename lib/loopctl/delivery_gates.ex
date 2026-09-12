defmodule Loopctl.DeliveryGates do
  @moduledoc """
  The two gates of the agent delivery loop. Pure: no I/O, no database, no model call, and no
  application environment read inside a gate. Everything a gate decides on is an argument.

  They are two gates and not one "escalation", because they answer different questions and
  fire at very different rates. Collapsing them into one path-based predicate was measured
  to escalate 54% of ordinary changes — the outcome both exist to prevent.

  ## Gate A — "Mark decides" (`gate_a/1`)

  Request-shaped. Reads only the triage trio's verdicts: it escalates when the request
  contradicts an existing story, KB decision or behaviour, inverts or removes behaviour a
  previous story deliberately added, changes a workflow rather than fixing a defect, or when
  the three agents' verdicts disagree. No file path enters it. Self-reported confidence is
  recorded and never gates. Its rate is reported with `gate_a_rate/1`; a rate resembling the
  collapsed predicate's is a design failure, not a tuning question.

  ## Gate B — "a human confirms" (`gate_b/3`, `judge_proof/3`)

  Effect-shaped. Asks whether the change can cause an irreversible external effect, from the
  paths it touches and the size of the diff. An effect path means the change proves its
  effect against a fixed fixture set (`judge_proof/3`): the output must change exactly
  where intended and nowhere else, and the fixtures must cover every code the repository
  uses. A human path, the size bound, or any failure to evaluate means a human confirms. A
  failed proof routes to Gate A.

  ## Both run twice

  At triage, over the trio's predicted touches, to decide whether to dispatch. Again as a
  merge precondition, over the real `gh pr diff --name-only` and diffstat. Nothing binds an
  implementing session to its story's prediction, so only the second run gates a merge.

  ## Fail closed

  Gate B's trigger data is configuration, never source (`parse_triggers/2`). A missing,
  empty, misparsed or checksum-mismatched document is an error, never an empty trigger set,
  and every gate evaluation handed anything but a valid parse escalates unconditionally,
  naming why. So do an unknown repository, a configured pattern that no longer matches any
  file in the repository, and malformed input to either gate.

  ## Agents may only add an escalation

  A property of the wiring, not a rule agents follow. Gate B computes its own triggers and
  ORs the agents' escalations onto them; it never reads an agent's negative, and no argument
  can remove a computed trigger. Gate A's inputs ARE agent judgements, so there the property
  is that any one agent escalating, contradicting, or disagreeing is enough.
  """

  alias Loopctl.DeliveryGates.GateA
  alias Loopctl.DeliveryGates.GateB
  alias Loopctl.DeliveryGates.Triggers

  @doc "See `Loopctl.DeliveryGates.Triggers.parse/2`."
  defdelegate parse_triggers(binary, expected_sha256_hex), to: Triggers, as: :parse

  @doc "See `Loopctl.DeliveryGates.GateA.evaluate/1`."
  defdelegate gate_a(trio_outputs), to: GateA, as: :evaluate

  @doc "See `Loopctl.DeliveryGates.GateA.rate/1`."
  defdelegate gate_a_rate(results), to: GateA, as: :rate

  @doc "See `Loopctl.DeliveryGates.GateB.evaluate/3`."
  defdelegate gate_b(phase, input, triggers), to: GateB, as: :evaluate

  @doc "See `Loopctl.DeliveryGates.GateB.judge_proof/3`."
  defdelegate judge_proof(intent, fixture_results, coverage), to: GateB
end
