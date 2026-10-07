defmodule Loopctl.Knowledge.ScaleSeedGuardTest do
  @moduledoc """
  The scale seeds refuse a connection inside a transaction block, the DataCase SQL sandbox's
  included, and run on an autocommitting one (`Loopctl.Knowledge.ScaleSeed.in_transaction_block?/1`).
  The seeds themselves are `:scale` tests; this pins only the guard, which runs before any
  row is written.
  """

  use Loopctl.DataCase, async: true

  alias Ecto.Adapters.SQL.Sandbox
  alias Loopctl.AdminRepo
  alias Loopctl.Knowledge.ScaleSeed
  alias Loopctl.Memory.ScaleSeed, as: MemoryScaleSeed

  test "a sandboxed test connection is inside a transaction block" do
    # Ecto cannot see the sandbox's wrapping transaction; the database can.
    refute AdminRepo.in_transaction?()
    assert ScaleSeed.in_transaction_block?(AdminRepo)
  end

  test "an unboxed connection is not" do
    # A fresh process holds no allowance, so `unboxed_run/2` gives it a connection of its own.
    unboxed =
      Task.async(fn ->
        Sandbox.unboxed_run(Loopctl.Repo, fn -> ScaleSeed.in_transaction_block?(AdminRepo) end)
      end)

    refute Task.await(unboxed)
  end

  test "every seed refuses a DataCase test connection before writing anything" do
    tenant = fixture(:tenant)

    for seed <- [
          fn -> ScaleSeed.seed(tenant.id, count: 1) end,
          fn -> ScaleSeed.seed_changes(tenant.id, count: 1) end,
          fn -> MemoryScaleSeed.seed_multi_subject(tenant.id, count: 1, floor: 1) end
        ] do
      assert_raise RuntimeError, ~r/inside a transaction\sblock/, seed
    end
  end
end
