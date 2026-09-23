defmodule Loopctl.Delivery.DispatchLeaseTest do
  @moduledoc """
  #879 (US-44.5) — the lease cap a placed claim gets, and the boot-time refusal of a grace
  below the runner capacity release grace (AC-44.5.6).

  The refusal is tested twice, because either half alone proves nothing: the VALIDATOR
  refuses a small grace, and `Loopctl.Application.start/2` CALLS it before the supervision
  tree starts. The second is read off the source's AST — a running test node cannot start the
  application again, and a boot check that is correct and never called is the failure this
  pins.
  """

  use ExUnit.Case, async: true

  alias Loopctl.Delivery.DispatchLease
  alias Loopctl.Runners.Capacity

  @application Path.expand("../../../lib/loopctl/application.ex", __DIR__)

  describe "validate!/1" do
    test "refuses a grace below the capacity release grace, naming both values" do
      error = assert_raise ArgumentError, fn -> DispatchLease.validate!(120) end

      assert error.message =~ "120"
      assert error.message =~ "#{Capacity.release_grace_seconds()}s"
      assert error.message =~ "DISPATCH_LEASE_GRACE_SECONDS"
    end

    test "the floor itself is accepted, and one second under it is not" do
      floor = Capacity.release_grace_seconds()
      assert floor == 300

      assert :ok = DispatchLease.validate!(floor)
      assert_raise ArgumentError, fn -> DispatchLease.validate!(floor - 1) end
    end

    test "a value that is not an integer is refused rather than coerced" do
      for bad <- [nil, "900", 900.0] do
        assert_raise ArgumentError, fn -> DispatchLease.validate!(bad) end
      end
    end
  end

  describe "validate!/0 and grace_seconds/0" do
    test "the configured grace is the default and passes" do
      assert DispatchLease.grace_seconds() == 900
      assert :ok = DispatchLease.validate!()
    end
  end

  describe "cap/2" do
    test "is placed_at + wall_clock_seconds + the grace" do
      placed_at = ~U[2026-09-23 10:00:00.000000Z]
      assert DispatchLease.cap(placed_at, 3_600) == ~U[2026-09-23 11:15:00.000000Z]
    end
  end

  describe "Loopctl.Application.start/2 (AC-44.5.6: the validator is WIRED)" do
    test "calls DispatchLease.validate!/0 before it starts the supervision tree" do
      calls = start_remote_calls()

      validate = Enum.find_index(calls, &(&1 == {Loopctl.Delivery.DispatchLease, :validate!, 0}))
      start_link = Enum.find_index(calls, &(&1 == {Supervisor, :start_link, 2}))

      assert validate, "Loopctl.Application.start/2 no longer calls DispatchLease.validate!/0"
      assert start_link
      assert validate < start_link
    end
  end

  # Every remote call in `start/2`'s body, in source order, as `{module, function, arity}`,
  # with the module's own `alias`es resolved — so the call is found however it is spelled.
  defp start_remote_calls do
    {:ok, ast} = @application |> File.read!() |> Code.string_to_quoted()

    {_ast, aliases} =
      Macro.prewalk(ast, %{}, fn
        {:alias, _, [{:__aliases__, _, parts}]} = node, acc ->
          {node, Map.put(acc, List.last(parts), parts)}

        node, acc ->
          {node, acc}
      end)

    {_ast, body} =
      Macro.prewalk(ast, nil, fn
        {:def, _, [{:start, _, [_, _]}, [do: body]]} = node, nil -> {node, body}
        node, acc -> {node, acc}
      end)

    assert body, "Loopctl.Application defines no start/2"

    {_body, calls} =
      Macro.prewalk(body, [], fn
        {{:., _, [{:__aliases__, _, [head | rest]}, fun]}, _, args} = node, acc
        when is_list(args) ->
          parts = Map.get(aliases, head, [head]) ++ rest
          {node, [{Module.concat(parts), fun, length(args)} | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(calls)
  end
end
