defmodule Loopctl.RemediationMatrixTest do
  @moduledoc """
  Pure unit tests for `Loopctl.RemediationMatrix`'s calibration derivation (US-27.13,
  AC-27.13.4a) — no DB, no 80k seed. The end-to-end census runs in
  `remediation_matrix_scale_test.exs` (`:scale_nightly`); this file pins the anti-rubber-stamp
  BOOLEAN derivation in isolation so all four corners are proven, including the nil-ef case
  that the scale test's injected-calibration path never makes the deciding factor (adversarial
  review F3).
  """
  use ExUnit.Case, async: true

  alias Loopctl.RemediationMatrix

  describe "calibrated_from_values?/3 — the anti-rubber-stamp derivation" do
    test "calibrated ONLY when seed >= floor AND ef_search is a readable (binary) value" do
      floor = 80_000

      # at/above floor + readable ef → calibrated
      assert RemediationMatrix.calibrated_from_values?(floor, floor, "40")
      assert RemediationMatrix.calibrated_from_values?(floor + 1, floor, "40")

      # at/above floor but ef NOT readable (nil) → NOT calibrated.
      # This is the corner the scale test never makes the deciding factor: a regression that
      # dropped the ef-search check from the derivation would be caught HERE.
      refute RemediationMatrix.calibrated_from_values?(floor, floor, nil)

      # sub-floor → NOT calibrated, regardless of ef readability
      refute RemediationMatrix.calibrated_from_values?(floor - 1, floor, "40")
      refute RemediationMatrix.calibrated_from_values?(floor - 1, floor, nil)
      refute RemediationMatrix.calibrated_from_values?(0, floor, "40")
    end
  end
end
