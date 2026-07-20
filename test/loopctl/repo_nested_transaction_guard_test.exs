defmodule Loopctl.RepoNestedTransactionGuardTest do
  @moduledoc """
  Covers the `with_tenant/2` nested-transaction guard (`Loopctl.Repo`).

  The guard cannot be exercised end-to-end here: `sandbox_pool?/0` is true for
  the whole suite (the test pool IS `Ecto.Adapters.SQL.Sandbox`), so a real
  nested `with_tenant/2` call NEVER raises under test. What CI can pin is the
  decision itself, plus the fact that the sandbox carve-out is deliberate — if
  someone flips the condition, these tests fail.

  Pure function calls, no DB — stays `async: true`.
  """
  use ExUnit.Case, async: true

  alias Loopctl.Repo

  test "raises when already inside a transaction on a non-sandbox pool" do
    assert_raise RuntimeError, ~r/must own its transaction/, fn ->
      Repo.assert_not_nested!(true, false)
    end
  end

  test "is inert under the SQL sandbox even when nested (the test-suite carve-out)" do
    assert Repo.assert_not_nested!(true, true) == :ok
  end

  test "passes when not inside a transaction" do
    assert Repo.assert_not_nested!(false, false) == :ok
    assert Repo.assert_not_nested!(false, true) == :ok
  end

  test "the test pool is the sandbox, which is why the guard is inert in CI" do
    assert Keyword.get(Repo.config(), :pool) == Ecto.Adapters.SQL.Sandbox
  end
end
