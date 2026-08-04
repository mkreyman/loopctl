defmodule Loopctl.ExitClassTest do
  @moduledoc """
  `error_class` is a Prometheus LABEL multiplied by `tenant_id`, so its whole job is to be a
  CLOSED vocabulary. These tests exist for the failing direction: the ways a caller quietly
  reopens it.
  """
  use ExUnit.Case, async: true

  alias Loopctl.ExitClass

  describe "classify/2 and bounded/2" do
    test "the closed tag set survives verbatim, prefixed by kind" do
      assert ExitClass.classify(:exit, {:noproc, {DBConnection, :execute, []}}) == "exit:noproc"
      assert ExitClass.classify(:exit, :shutdown) == "exit:shutdown"
      assert ExitClass.bounded(:throw, "timeout") == "throw:timeout"
    end

    test "anything outside the set collapses to ONE catch-all, not two spellings of it" do
      # `ExitTag`'s catch-all is "unknown" and this module's is "other"; a metric wants one
      # label for "could not classify", so "unknown" lands on "other" too.
      assert ExitClass.classify(:exit, {:some, :novel, :shape}) == "exit:other"
      assert ExitClass.bounded(:exit, "unknown") == "exit:other"
      assert ExitClass.bounded(:exit, "a-tenant-id-or-any-other-unbounded-string") == "exit:other"
    end

    test "#572: :raise is a first-class kind, so a rescue arm need not hand-roll the prefix" do
      # It was `:exit | :throw` only, so a rescue site wanting a class wrote
      # `"raise:" <> ExitTag.tag(e)` by hand — which looks identical in a log line while the
      # TAG behind it is UNBOUNDED. That is how a closed vocabulary springs a leak: the
      # cardinality cap is in `bounded/2`, and hand-rolling routes around it.
      assert ExitClass.classify(:raise, %DBConnection.ConnectionError{message: "x"}) ==
               "raise:DBConnection.ConnectionError"

      assert ExitClass.classify(:raise, %RuntimeError{message: "anything at all"}) ==
               "raise:other"
    end

    test "an unknown KIND raises rather than inventing a prefix" do
      assert_raise FunctionClauseError, fn -> ExitClass.bounded(:oops, "noproc") end
    end
  end

  describe "pool_exit?/1" do
    test "places an exit whose call element names a pool module" do
      assert ExitClass.pool_exit?({:noproc, {DBConnection, :execute, []}})
      assert ExitClass.pool_exit?({{%RuntimeError{message: "x"}, []}, {Postgrex, :query, []}})
    end

    test "is CONSERVATIVE — what it cannot place is not a pool exit" do
      # A caller maps this onto a retryable 503/429, so a foreign GenServer timeout dressed
      # up as a database outage is the failure that matters.
      refute ExitClass.pool_exit?({:timeout, {GenServer, :call, [:some_pid, :req]}})
      refute ExitClass.pool_exit?(:shutdown)
      refute ExitClass.pool_exit?({:noproc, :not_even_a_call_tuple})
    end
  end
end
