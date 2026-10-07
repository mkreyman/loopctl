defmodule Loopctl.HeavyReadPoolIsolationTest do
  @moduledoc """
  TC-27.11.1: K concurrent heavy reads don't starve other admin ops.

  The real protection is STRUCTURAL: `HeavyReadRepo` and `AdminRepo` are distinct
  Ecto repos with distinct, independently-sized DBConnection pools, so saturating
  one cannot consume the other's connections; and the per-read `statement_timeout`
  (applied via SET LOCAL inside the heavy-read transaction path — US-27.13, the
  pgbouncer-safe lever) bounds how long any heavy read can hold a connection, so even
  a fully-saturated heavy pool self-drains. (True OS-level pool starvation is not
  reproducible under `Ecto.Adapters.SQL.Sandbox`, which multiplexes a test's queries
  onto a single checked-out connection — so this asserts the structural guarantees
  plus a no-deadlock concurrency smoke, not a starvation race.)
  """
  use Loopctl.DataCase, async: false

  alias Loopctl.AdminRepo
  alias Loopctl.HeavyReadRepo

  test "heavy reads and light admin ops are on separate, independently-sized pools" do
    refute HeavyReadRepo == AdminRepo

    heavy_cfg = Application.get_env(:loopctl, HeavyReadRepo)
    admin_cfg = Application.get_env(:loopctl, AdminRepo)
    assert is_integer(heavy_cfg[:pool_size]) and heavy_cfg[:pool_size] > 0
    assert is_integer(admin_cfg[:pool_size]) and admin_cfg[:pool_size] > 0
  end

  test "K concurrent heavy reads complete while a light admin read still succeeds (no deadlock)" do
    k = 6

    tasks =
      for _ <- 1..k do
        Task.async(fn -> HeavyReadRepo.query!("SELECT 1").rows end)
      end

    # The light admin read is on a different pool — it must not be blocked.
    assert AdminRepo.query!("SELECT 1").rows == [[1]]

    assert Enum.all?(Task.await_many(tasks, 5_000), &(&1 == [[1]]))
  end

  test "statement_timeout self-drains the heavy pool: a long heavy read is canceled, not held" do
    # US-27.13: the server-side statement_timeout is applied per-read via SET LOCAL inside a
    # transaction (the read path; pgbouncer-safe), NOT a pool startup `:parameters`. A long
    # heavy read under that SET LOCAL self-cancels (query_canceled) rather than holding the
    # connection until the client timeout.
    result =
      HeavyReadRepo.transaction(fn ->
        HeavyReadRepo.query!("SET LOCAL statement_timeout = 250")

        case HeavyReadRepo.query("SELECT pg_sleep(1)") do
          {:error, error} -> HeavyReadRepo.rollback(error)
          ok -> ok
        end
      end)

    assert {:error, %Postgrex.Error{postgres: %{code: :query_canceled}}} = result
  end

  test "SET LOCAL statement_timeout does NOT carry over between consecutive transactions" do
    # Regression guard for F1: SET LOCAL is transaction-scoped, not connection-scoped. A
    # statement_timeout set in one transaction must not affect the next transaction on the
    # same reused connection. This test proves `SET LOCAL` ends at COMMIT and doesn't leak.
    # If it leaked, the second transaction would also be subject to the 250ms timeout and
    # would fail. Instead, it succeeds (the 1-second sleep completes).

    # First transaction: set a short timeout and run pg_sleep(1), which gets canceled.
    result1 =
      HeavyReadRepo.transaction(fn ->
        HeavyReadRepo.query!("SET LOCAL statement_timeout = 250")

        case HeavyReadRepo.query("SELECT pg_sleep(1)") do
          {:error, error} -> HeavyReadRepo.rollback(error)
          ok -> ok
        end
      end)

    assert {:error, %Postgrex.Error{postgres: %{code: :query_canceled}}} = result1

    # Second transaction on the same connection: NO SET LOCAL. The 1-second sleep should
    # complete without timing out, proving the first transaction's SET LOCAL didn't carry over.
    result2 =
      HeavyReadRepo.transaction(fn ->
        # No SET LOCAL here — we're relying on the fact that the timeout from transaction 1
        # should have been reset.
        HeavyReadRepo.query!("SELECT pg_sleep(0.5)") |> Map.get(:rows)
      end)

    # pg_sleep returns the `void` type, which Postgrex decodes to the atom `:void`.
    assert {:ok, [[:void]]} = result2,
           "expected second transaction to complete without inheriting the 250ms timeout from the first"
  end
end
