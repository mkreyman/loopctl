defmodule Loopctl.ApplicationBootOrderTest do
  @moduledoc """
  GH #588: the SystemConfig cache prime must be ORDERED ahead of every consumer of
  that cache, not merely fast. A supervisor starts children synchronously in list
  order, so `Loopctl.Application.children/0` IS the guarantee — these assertions
  are static list indexes, never timing.
  """
  use ExUnit.Case, async: true

  alias Loopctl.SystemConfig.CachePrimer

  # The child list entries are bare module atoms or `{Module, opts}` tuples;
  # match the raw entry rather than resolving child specs.
  defp index_of(children, module) do
    Enum.find_index(children, fn
      ^module -> true
      {^module, _opts} -> true
      _ -> false
    end)
  end

  describe "children/0 ordering (AC: primed before the Endpoint starts)" do
    test "the SystemConfig cache primer sits after AdminRepo and before Oban and the Endpoint" do
      children = Loopctl.Application.children()

      admin_repo_idx = index_of(children, Loopctl.AdminRepo)
      primer_idx = index_of(children, CachePrimer)
      oban_idx = index_of(children, Oban)
      endpoint_idx = index_of(children, LoopctlWeb.Endpoint)

      # ANTI-VACUITY: a rename must FAIL this test, not silently turn every
      # comparison below into `nil < nil`. Assert each child was actually found
      # before comparing positions.
      assert is_integer(admin_repo_idx), "Loopctl.AdminRepo is not in Application.children/0"
      assert is_integer(primer_idx), "#{inspect(CachePrimer)} is not in Application.children/0"
      assert is_integer(oban_idx), "Oban is not in Application.children/0"
      assert is_integer(endpoint_idx), "LoopctlWeb.Endpoint is not in Application.children/0"

      # After its data source: refresh/0 reads system_configs through AdminRepo.
      assert admin_repo_idx < primer_idx

      # Before every consumer that can read the cache. Oban matters as much as the
      # Endpoint: the embedding/ingestion workers read the read-routing flag too.
      assert primer_idx < oban_idx
      assert primer_idx < endpoint_idx
    end

    test "the Endpoint is still last, so nothing serves requests ahead of the tree" do
      children = Loopctl.Application.children()
      assert List.last(children) == LoopctlWeb.Endpoint
    end
  end

  describe "live supervision-tree wiring" do
    test "the primer is a child of the running tree with pid :undefined (it returned :ignore)" do
      children = Supervisor.which_children(Loopctl.Supervisor)

      primer_child = Enum.find(children, fn {id, _pid, _type, _mods} -> id == CachePrimer end)

      # pid is :undefined precisely BECAUSE start_link/1 returned :ignore after
      # priming synchronously — and the spec is retained (rather than discarded)
      # because the child spec declares restart: :transient, not :temporary.
      assert {CachePrimer, :undefined, :worker, _modules} = primer_child
    end
  end
end
