defmodule Loopctl.HeavyReadSavepointProbeTest do
  @moduledoc """
  Pins both premises `HeavyRead.probe_iterative_scan_support/0`'s savepoint
  handling rests on: Postgrex REFUSES `mode: :savepoint` on an idle connection
  (so the probe must retry plainly), and `in_transaction?/0` CANNOT be used to
  decide that, because it reports false under the sandbox — where the backend
  genuinely is in a transaction.

  The first exists because the premise was challenged and the challenge was
  wrong. A review round proposed passing `mode: :savepoint` unconditionally, to
  match `LocalGuc.do_capture/2` — which is unconditional because it only ever
  runs inside a transaction. `probe_iterative_scan_support/0` does not:
  `HeavyRead.opts/1` runs OUTSIDE any transaction in production.

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
      # The sandbox checks out a connection inside a transaction; this module is
      # async: false so a dedicated non-sandboxed checkout still wins ownership
      # for this process, leaving the connection genuinely idle — the prod shape
      # of HeavyRead.opts/1. Assert it TOOK: checkout/2 returns
      # `{:already, :owner | :allowed}` instead of raising when the process is
      # already bound to a sandboxed connection, and the query would then run
      # inside the sandbox transaction, testing nothing. `in_transaction?/0`
      # cannot stand in for this check (see the test below).
      assert :ok = Sandbox.checkout(HeavyReadRepo, sandbox: false)

      result = HeavyReadRepo.query("SELECT 1", [], timeout: 2_000, mode: :savepoint)

      assert {:error, %DBConnection.TransactionError{status: :idle}} = result,
             "savepoint-on-idle must stay refused — probe_iterative_scan_support/0's " <>
               "in_transaction? gate depends on it. Got: #{inspect(result)}"
    end

    test "the same query without savepoint mode succeeds on that idle connection" do
      # Establishes that the refusal above is caused by `mode: :savepoint` and
      # not by the connection being unusable — without this, the assertion could
      # pass for the wrong reason and keep passing after the premise changed.
      assert :ok = Sandbox.checkout(HeavyReadRepo, sandbox: false)

      assert {:ok, %{rows: [[1]]}} = HeavyReadRepo.query("SELECT 1", [], timeout: 2_000)
    end
  end

  describe "savepoint mode inside the sandbox transaction" do
    test "succeeds while in_transaction?/0 reports false" do
      # No `sandbox: false` checkout: this is the SANDBOXED shape, where the
      # backend is inside a transaction that a probe error would poison (25P02).
      # `in_transaction?/0` still says false — it reads a per-process key that
      # `Sandbox.start_owner!/2` never sets — so gating the probe's
      # `mode: :savepoint` on it made the protection dead exactly here.
      refute HeavyReadRepo.in_transaction?()

      assert {:ok, %{rows: [[1]]}} =
               HeavyReadRepo.query("SELECT 1", [], timeout: 2_000, mode: :savepoint)
    end
  end
end
