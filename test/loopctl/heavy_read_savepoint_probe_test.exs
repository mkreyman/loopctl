defmodule Loopctl.HeavyReadSavepointProbeTest do
  @moduledoc """
  Pins the premise `HeavyRead.probe_iterative_scan_support/0` gates its
  `mode: :savepoint` on: DBConnection REFUSES savepoint mode on an idle
  connection.

  This exists because the premise was challenged and the challenge was wrong.
  A review round proposed dropping the `repo().in_transaction?()` gate and
  passing `mode: :savepoint` unconditionally, to match `LocalGuc.do_capture/2`
  — which is unconditional because it only ever runs inside a transaction.
  `probe_iterative_scan_support/0` does not: `HeavyRead.opts/1` runs OUTSIDE any
  transaction in production.

  The failure that change would cause is silent, which is why it earns a test
  rather than a comment. Savepoint-on-idle returns an ERROR TUPLE, not a raise,
  so it lands in the probe's `other ->` branch and reports `:inconclusive` — on
  every prod probe. With no conclusive verdict to reuse, `inconclusive_verdict/2`
  fails closed, iterative scan is disabled fleet-wide, and ANN reads silently
  under-return. That is the exact defect #535 fixed.

  Asserted against `DBConnection` behaviour rather than the probe's own return
  value on purpose: the probe rescues and classifies, so a test driving it would
  pass under BOTH the conditional and unconditional forms and prove nothing.
  """

  use Loopctl.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Loopctl.HeavyReadRepo

  setup :verify_on_exit!

  describe "savepoint mode on an idle connection" do
    test "is refused with a TransactionError, not silently accepted" do
      # The sandbox checks out a connection inside a transaction for async
      # cases; this module is async: false and uses a dedicated non-sandboxed
      # checkout so the connection is genuinely idle, matching the prod shape of
      # HeavyRead.opts/1.
      Sandbox.checkout(HeavyReadRepo, sandbox: false)

      refute HeavyReadRepo.in_transaction?(),
             "this test is meaningless unless the connection is idle"

      result = HeavyReadRepo.query("SELECT 1", [], timeout: 2_000, mode: :savepoint)

      assert {:error, %DBConnection.TransactionError{status: :idle}} = result,
             "savepoint-on-idle must stay refused — probe_iterative_scan_support/0's " <>
               "in_transaction? gate depends on it. Got: #{inspect(result)}"
    end

    test "the same query without savepoint mode succeeds on that idle connection" do
      # Establishes that the refusal above is caused by `mode: :savepoint` and
      # not by the connection being unusable — without this, the assertion could
      # pass for the wrong reason and keep passing after the premise changed.
      Sandbox.checkout(HeavyReadRepo, sandbox: false)

      assert {:ok, %{rows: [[1]]}} = HeavyReadRepo.query("SELECT 1", [], timeout: 2_000)
    end
  end
end
