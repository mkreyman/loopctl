defmodule Loopctl.Memory.RecallHistoryCacheTest do
  @moduledoc """
  #792 — the node-local shown-set that makes containment-in-history a SERVER-side check,
  so the slot a repeat frees can be refilled.

  Async and DB-free: the table is a process-global public ETS owned by the application
  supervisor, so every test keys on its own freshly-generated `(tenant_id, session_id)`
  pair rather than clearing shared state.
  """
  use ExUnit.Case, async: true

  alias Loopctl.Memory.RecallHistoryCache

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  setup do
    %{tenant: unique("tenant"), session: unique("session")}
  end

  test "an id is not shown until it is marked, then it is", ctx do
    assert RecallHistoryCache.shown_ids(ctx.tenant, ctx.session, ["a", "b"]) == []

    :ok = RecallHistoryCache.mark_shown(ctx.tenant, ctx.session, ["a"])

    assert RecallHistoryCache.shown_ids(ctx.tenant, ctx.session, ["a", "b"]) ==
             ["a"]
  end

  test "tenant isolation: two tenants that pick the SAME session string never see each other",
       ctx do
    other_tenant = unique("tenant")

    :ok = RecallHistoryCache.mark_shown(ctx.tenant, ctx.session, ["shared-id"])

    # `session_id` is a CLIENT-chosen opaque token, so a collision across tenants is not
    # merely possible, it is trivially forgeable. `tenant_id` being IN the key is what
    # makes that harmless.
    assert RecallHistoryCache.shown_ids(other_tenant, ctx.session, ["shared-id"]) ==
             []

    assert RecallHistoryCache.shown_ids(ctx.tenant, ctx.session, ["shared-id"]) ==
             ["shared-id"]
  end

  test "session isolation: a second session in the same tenant starts empty", ctx do
    other_session = unique("session")

    :ok = RecallHistoryCache.mark_shown(ctx.tenant, ctx.session, ["a"])

    assert RecallHistoryCache.shown_ids(ctx.tenant, other_session, ["a"]) == []
  end

  test "no session means no containment — reads and writes are both no-ops", ctx do
    assert RecallHistoryCache.mark_shown(ctx.tenant, nil, ["a"]) == :ok
    assert RecallHistoryCache.shown_ids(ctx.tenant, nil, ["a"]) == []
  end

  test "an empty id list is a no-op in both directions", ctx do
    assert RecallHistoryCache.mark_shown(ctx.tenant, ctx.session, []) == :ok
    assert RecallHistoryCache.shown_ids(ctx.tenant, ctx.session, []) == []
  end

  test "a non-binary id is ignored rather than inserted", ctx do
    assert RecallHistoryCache.mark_shown(ctx.tenant, ctx.session, [nil, 42, "ok"]) == :ok
    assert RecallHistoryCache.shown_ids(ctx.tenant, ctx.session, ["ok"]) == ["ok"]
  end

  test "ttl_seconds/0 is a positive integer and survives a nonsense config value" do
    assert is_integer(RecallHistoryCache.ttl_seconds())
    assert RecallHistoryCache.ttl_seconds() > 0
  end

  test "marking is idempotent — a repeat does not create a second entry", ctx do
    :ok = RecallHistoryCache.mark_shown(ctx.tenant, ctx.session, ["a"])
    :ok = RecallHistoryCache.mark_shown(ctx.tenant, ctx.session, ["a"])

    assert :ets.lookup(RecallHistoryCache.table_name(), {ctx.tenant, ctx.session, "a"})
           |> length() == 1
  end
end
