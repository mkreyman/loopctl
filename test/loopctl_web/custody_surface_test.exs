defmodule LoopctlWeb.CustodySurfaceTest do
  @moduledoc """
  Binds the DECLARED custody surface to the routes the router actually exposes.

  A custody halt is scoped rather than total, which creates a new failure mode:
  a story-lifecycle route added later would escape the halt silently, because
  nothing about adding a route forces anyone to look at `CustodySurface`. This
  test walks `LoopctlWeb.Router.__routes__/0` and fails in that case. Do not relax it
  to make a new route pass — classify the route instead.

  The opposite direction is asserted too: no read is ever custody surface, and
  the surfaces a halted operator needs in order to INVESTIGATE stay reachable.
  """
  use ExUnit.Case, async: true

  alias LoopctlWeb.CustodySurface

  @mutating_verbs [:post, :put, :patch, :delete]

  defp conn_for(verb, path) do
    %Plug.Conn{
      method: verb |> to_string() |> String.upcase(),
      path_info: path |> String.trim_leading("/") |> String.split("/")
    }
  end

  # Router paths carry `:id` placeholders; substitute a concrete UUID so the
  # matcher sees the shape a real request has.
  defp concrete(path) do
    path
    |> String.split("/")
    |> Enum.map_join("/", fn
      ":" <> _param -> Ecto.UUID.generate()
      "*" <> _glob -> Ecto.UUID.generate()
      segment -> segment
    end)
  end

  defp mutating_routes_for(controller) do
    LoopctlWeb.Router.__routes__()
    |> Enum.filter(&(&1.plug == controller and &1.verb in @mutating_verbs))
  end

  describe "router binding — every custody controller's mutating routes are classified" do
    test "no mutating route on a custody controller escapes the halt" do
      unclassified =
        for {controller, coverage} <- CustodySurface.custody_controllers(),
            route <- mutating_routes_for(controller),
            covered_action?(coverage, route.plug_opts),
            not CustodySurface.custody_operation?(conn_for(route.verb, concrete(route.path))),
            do: "#{route.verb |> to_string() |> String.upcase()} #{route.path}"

      assert unclassified == [],
             "these mutating custody routes are NOT classified as custody surface, so a " <>
               "custody halt would not stop them: #{inspect(unclassified, pretty: true)}"
    end

    test "the scan is not vacuous — it actually found routes on every declared controller" do
      for {controller, _coverage} <- CustodySurface.custody_controllers() do
        assert mutating_routes_for(controller) != [],
               "#{inspect(controller)} is declared a custody controller but the router " <>
                 "exposes no mutating route for it — the declaration is stale"
      end
    end
  end

  defp covered_action?(:all_mutating, _action), do: true
  defp covered_action?({:all_mutating_except, excluded}, action), do: action not in excluded

  describe "reads are never custody surface" do
    test "GET is never blocked, even on a custody path" do
      refute CustodySurface.custody_operation?(
               conn_for(:get, "/api/v1/stories/#{Ecto.UUID.generate()}/artifacts")
             )

      refute CustodySurface.custody_operation?(conn_for(:get, "/api/v1/stories/ready"))
      refute CustodySurface.custody_operation?(conn_for(:get, "/api/v1/memory"))
      refute CustodySurface.custody_operation?(conn_for(:get, "/api/v1/audit"))
    end

    test "the surfaces an operator investigates a halt with stay reachable" do
      for path <- [
            "/api/v1/knowledge/search",
            "/api/v1/knowledge/index",
            "/api/v1/audit",
            "/api/v1/changes",
            "/api/v1/custody/failures",
            "/api/v1/stories/#{Ecto.UUID.generate()}/history"
          ] do
        refute CustodySurface.custody_operation?(conn_for(:get, path)),
               "#{path} must stay readable during a custody halt"
      end
    end
  end

  describe "the blocked set" do
    test "story lifecycle writes are custody surface" do
      story = Ecto.UUID.generate()

      for op <- ~w(contract claim start request-review report unclaim report-done
                   start-work review-complete verify reject backfill force-unclaim
                   recover-cap artifacts) do
        assert CustodySurface.custody_operation?(
                 conn_for(:post, "/api/v1/stories/#{story}/#{op}")
               ),
               "POST /stories/:id/#{op} must be blocked by a custody halt"
      end
    end

    test "bulk story operations and epic verify-all are custody surface" do
      for path <- [
            "/api/v1/stories/bulk/claim",
            "/api/v1/stories/bulk/verify",
            "/api/v1/stories/bulk/reject",
            "/api/v1/stories/bulk/mark-complete",
            "/api/v1/epics/#{Ecto.UUID.generate()}/verify-all"
          ] do
        assert CustodySurface.custody_operation?(conn_for(:post, path))
      end
    end

    test "minting a dispatch is custody surface" do
      assert CustodySurface.custody_operation?(conn_for(:post, "/api/v1/dispatches"))
    end

    test "memory writes are custody surface — recall included, it is not the read its verb claims" do
      assert CustodySurface.custody_operation?(conn_for(:post, "/api/v1/memory"))
      assert CustodySurface.custody_operation?(conn_for(:post, "/api/v1/memory/promote"))
      assert CustodySurface.custody_operation?(conn_for(:post, "/api/v1/memory/graduate"))

      assert CustodySurface.custody_operation?(
               conn_for(:delete, "/api/v1/memory/#{Ecto.UUID.generate()}")
             )

      # `Memory.recall/2` bumps recall_count / last_recalled_at on what it
      # returns — the hotness a graduation can promote into a durable article.
      assert CustodySurface.custody_operation?(conn_for(:post, "/api/v1/memory/recall"))
      assert CustodySurface.custody_operation?(conn_for(:post, "/api/v1/recall"))

      # And everything UNDER /recall, which is why the clause matches a tail rather than
      # the bare segment: `POST /recall/:recall_id/referenced` writes an analytics row, and
      # a route added under this prefix later must not escape the halt silently.
      assert CustodySurface.custody_operation?(
               conn_for(:post, "/api/v1/recall/#{Ecto.UUID.generate()}/referenced")
             )

      # The oversight read stays open.
      refute CustodySurface.custody_operation?(conn_for(:get, "/api/v1/memory"))
    end

    test "project import is custody surface — it records work as done" do
      assert CustodySurface.custody_operation?(
               conn_for(:post, "/api/v1/projects/#{Ecto.UUID.generate()}/import")
             )
    end

    test "deleting the custody evidence is custody surface" do
      for coll <- ~w(stories epics projects) do
        assert CustodySurface.custody_operation?(
                 conn_for(:delete, "/api/v1/#{coll}/#{Ecto.UUID.generate()}")
               ),
               "DELETE /#{coll}/:id destroys the record a halt was armed over"
      end

      # Still a read, and still readable.
      refute CustodySurface.custody_operation?(
               conn_for(:get, "/api/v1/stories/#{Ecto.UUID.generate()}")
             )
    end
  end

  describe "the deliberately-open set" do
    test "knowledge-wiki and coordination writes are not custody surface" do
      for path <- [
            "/api/v1/knowledge/ingest",
            "/api/v1/knowledge/hybrid_search",
            "/api/v1/channel/posts",
            "/api/v1/channel/locks"
          ] do
        refute CustodySurface.custody_operation?(conn_for(:post, path)),
               "#{path} is not custody progress and must not be frozen by a halt"
      end
    end

    test "root-of-trust rotation stays reachable — it is a remediation path" do
      refute CustodySurface.custody_operation?(
               conn_for(:post, "/api/v1/tenants/me/custody-owner-key")
             )

      refute CustodySurface.custody_operation?(
               conn_for(:post, "/api/v1/tenants/#{Ecto.UUID.generate()}/rotate-audit-key")
             )
    end

    test "the superadmin break-glass is not custody surface" do
      refute CustodySurface.custody_operation?(
               conn_for(:post, "/api/v1/admin/tenants/#{Ecto.UUID.generate()}/clear-halt")
             )
    end

    test "a path outside /api/v1 is never custody surface" do
      refute CustodySurface.custody_operation?(conn_for(:post, "/signup"))
    end
  end
end
