defmodule Loopctl.Custody.CoverageBehaviour do
  @moduledoc """
  US-41.7 AC-41.7.6 — the DI seam for the custody claim's COVERAGE field.

  Coverage is the set of egress paths the attestation actually covers. It is
  driven by configuration (`config :loopctl, :custody_coverage, ...`) rather than
  hardcoded, because a claim that silently widened its own scope as new paths
  were instrumented would overstate exactly where this story insists on
  precision.

  A callback, not a bare `Application.get_env`, so TC-41.7.8 can exercise BOTH
  configurations (webhook coverage enabled / disabled) without `put_env` in a
  test file (CLAUDE.md test rule 2).
  """

  @doc """
  The egress paths this deployment's custody claims cover.

  Implementations MUST NOT return a path for which no per-row posture entry is
  ever recorded — see `Loopctl.Custody.Coverage`, which intersects the configured
  set with the INSTRUMENTED set so the production surface can never over-claim.
  """
  @callback covered_paths() :: [atom()]
end
