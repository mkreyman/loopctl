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

  The premise tests assert `DBConnection` behaviour, not the probe's return
  value: on the CONDITIONAL-vs-UNCONDITIONAL question a test driving it proved
  nothing. Not so for the RETRY, which therefore drives the probe end to end.
  All of it runs against `HeavyRead.repo/0` — the repo the probe actually uses
  (`config/test.exs` points it at `AdminRepo`), not `HeavyReadRepo`.
  """

  use Loopctl.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Loopctl.HeavyRead

  setup :verify_on_exit!

  @last_conclusive_key {HeavyRead, :iterative_scan_last_conclusive}
  @probe_cache_keys [
    {HeavyRead, :iterative_scan_supported},
    @last_conclusive_key,
    {HeavyRead, :iterative_scan_guess_ttl}
  ]

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
      assert :ok = Sandbox.checkout(HeavyRead.repo(), sandbox: false)

      result = HeavyRead.repo().query("SELECT 1", [], timeout: 2_000, mode: :savepoint)

      assert {:error, %DBConnection.TransactionError{status: :idle}} = result,
             "savepoint-on-idle must stay refused — probe_iterative_scan_support/0's " <>
               "in_transaction? gate depends on it. Got: #{inspect(result)}"
    end

    test "the same query without savepoint mode succeeds on that idle connection" do
      # Establishes that the refusal above is caused by `mode: :savepoint` and
      # not by the connection being unusable — without this, the assertion could
      # pass for the wrong reason and keep passing after the premise changed.
      assert :ok = Sandbox.checkout(HeavyRead.repo(), sandbox: false)

      assert {:ok, %{rows: [[1]]}} = HeavyRead.repo().query("SELECT 1", [], timeout: 2_000)
    end

    test "the probe reaches a CONCLUSIVE verdict there — the retry, driven end to end" do
      # Drop the retry and the refusal above lands in the probe's `other ->` branch:
      # every prod probe inconclusive, fails closed, iterative scan off fleet-wide.
      # Asserted on the last-CONCLUSIVE record, not on `true`, so it means "the backend
      # answered" for any installed pgvector version.
      assert :ok = Sandbox.checkout(HeavyRead.repo(), sandbox: false)
      clear_probe_cache()
      on_exit(&clear_probe_cache/0)

      verdict = HeavyRead.iterative_scan_supported?()
      recorded = :persistent_term.get(@last_conclusive_key, :none)

      assert match?({answered, _at} when is_boolean(answered), recorded),
             "the probe was INCONCLUSIVE on an idle connection (got #{inspect(recorded)}) — " <>
               "the savepoint retry is gone"

      assert {^verdict, _at} = recorded
    end
  end

  describe "savepoint refusal on an ABORTED connection" do
    test "classifies as :transaction, so it is never negative-cached" do
      # Postgrex refuses savepoint mode on a poisoned connection too, returning the
      # refusal instead of the 25P02 `Postgrex.Error`. The `:pool` catch-all IS
      # negative-cached in prod, which would pin the operator's lever OFF.
      aborted = %DBConnection.TransactionError{status: :error, message: "transaction is aborted"}

      assert HeavyRead.inconclusive_class(aborted) == :transaction
      assert HeavyRead.inconclusive_class({:error, aborted}) == :transaction
    end
  end

  describe "savepoint mode inside the sandbox transaction" do
    test "succeeds while in_transaction?/0 reports false" do
      # No `sandbox: false` checkout: this is the SANDBOXED shape, where the
      # backend is inside a transaction that a probe error would poison (25P02).
      # `in_transaction?/0` still says false — it reads a per-process key that
      # `Sandbox.start_owner!/2` never sets — so gating the probe's
      # `mode: :savepoint` on it made the protection dead exactly here.
      refute HeavyRead.repo().in_transaction?()

      assert {:ok, %{rows: [[1]]}} =
               HeavyRead.repo().query("SELECT 1", [], timeout: 2_000, mode: :savepoint)
    end
  end

  defp clear_probe_cache, do: Enum.each(@probe_cache_keys, &:persistent_term.erase/1)
end
