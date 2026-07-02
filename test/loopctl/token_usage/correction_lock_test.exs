defmodule Loopctl.TokenUsage.CorrectionLockTest do
  @moduledoc """
  Deterministic proof that the per-story correction advisory lock (tokens-02)
  genuinely SERIALIZES concurrent corrections across separate DB sessions — the
  guarantee that closes the double-submit race, not the fast re-validation.

  A true two-`Task.async` `create_correction/4` race cannot distinguish "lock
  present" from "lock absent" under `Ecto.Adapters.SQL.Sandbox`: the sandbox
  multiplexes every allowed process onto ONE checked-out connection, so
  connection-level serialization alone already makes the loser re-read the
  winner's committed total (verified empirically — removing the lock leaves that
  invariant test green). So the lock is proven in two deterministic parts:

    1. `token_usage_corrections_test.exs` asserts (via query telemetry) that
       `create_correction/4` actually issues `pg_advisory_xact_lock` with
       `correction_lock_key/2` — fails if the lock step is removed.
    2. THIS test proves that lock, on the exact key, blocks a SECOND real DB
       session (not re-entrant on one connection) — using two `sandbox: false`
       connections so they are genuinely independent.

  Uses real (committing) connections, so `async: false`.
  """

  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Loopctl.AdminRepo
  alias Loopctl.TokenUsage

  describe "correction_lock_key/2 (tokens-02, FIX 6)" do
    test "is deterministic, scoped to (tenant, story), and in signed 64-bit range" do
      tenant = Ecto.UUID.generate()
      story = Ecto.UUID.generate()

      key = TokenUsage.correction_lock_key(tenant, story)

      assert is_integer(key)
      # Release-independent: same inputs always yield the same key.
      assert TokenUsage.correction_lock_key(tenant, story) == key
      # Scoped: a different story or tenant yields a different key.
      refute TokenUsage.correction_lock_key(tenant, Ecto.UUID.generate()) == key
      refute TokenUsage.correction_lock_key(Ecto.UUID.generate(), story) == key
      # Fits a PostgreSQL bigint advisory lock key.
      assert key >= -0x8000_0000_0000_0000
      assert key <= 0x7FFF_FFFF_FFFF_FFFF
    end
  end

  describe "advisory lock serialization across sessions (tokens-02)" do
    test "the per-story lock blocks a second real session while held, and frees on release" do
      tenant = Ecto.UUID.generate()
      story = Ecto.UUID.generate()
      key = TokenUsage.correction_lock_key(tenant, story)

      parent = self()

      # Holder: an independent real session that grabs the xact lock inside an
      # open transaction and waits, so the lock stays held.
      holder =
        Task.async(fn ->
          :ok = Sandbox.checkout(AdminRepo, sandbox: false)

          AdminRepo.transaction(fn ->
            AdminRepo.query!("SELECT pg_advisory_xact_lock($1)", [key])
            send(parent, :locked)

            receive do
              :release -> :ok
            end
          end)
        end)

      assert_receive :locked, 2_000

      # A DIFFERENT real session must NOT be able to take the same xact lock
      # while the holder's transaction holds it. If the lock were a no-op or
      # re-entrant per-connection, this try would wrongly succeed.
      :ok = Sandbox.checkout(AdminRepo, sandbox: false)

      %{rows: [[got_while_held]]} =
        AdminRepo.query!("SELECT pg_try_advisory_xact_lock($1)", [key])

      refute got_while_held

      # Release the holder; the lock frees so a fresh session can take it.
      send(holder.pid, :release)
      Task.await(holder, 2_000)

      %{rows: [[got_after_release]]} =
        AdminRepo.query!("SELECT pg_try_advisory_xact_lock($1)", [key])

      assert got_after_release
    end
  end
end
