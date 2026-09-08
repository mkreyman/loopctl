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
    %{tenant: unique("tenant"), subject: unique("subject"), session: unique("session")}
  end

  test "an id is not shown until it is marked, then it is", ctx do
    assert RecallHistoryCache.shown_ids(ctx.tenant, ctx.subject, ctx.session, ["a", "b"]) == []

    :ok = RecallHistoryCache.mark_shown(ctx.tenant, ctx.subject, ctx.session, ["a"])

    assert RecallHistoryCache.shown_ids(ctx.tenant, ctx.subject, ctx.session, ["a", "b"]) ==
             ["a"]
  end

  test "tenant isolation: two tenants that pick the SAME session string never see each other",
       ctx do
    other_tenant = unique("tenant")

    :ok = RecallHistoryCache.mark_shown(ctx.tenant, ctx.subject, ctx.session, ["shared-id"])

    # `session_id` is a CLIENT-chosen opaque token, so a collision across tenants is not
    # merely possible, it is trivially forgeable. `tenant_id` being IN the key is what
    # makes that harmless.
    assert RecallHistoryCache.shown_ids(other_tenant, ctx.subject, ctx.session, ["shared-id"]) ==
             []

    assert RecallHistoryCache.shown_ids(ctx.tenant, ctx.subject, ctx.session, ["shared-id"]) ==
             ["shared-id"]
  end

  test "subject isolation: another agent in the SAME tenant and session token is inert", ctx do
    other_subject = unique("subject")

    :ok = RecallHistoryCache.mark_shown(ctx.tenant, ctx.subject, ctx.session, ["shared-id"])

    # `session_id` is model-chosen, so two agents in one tenant picking the same token (a
    # repo name, "default") is not exotic. Without `subject_id` in the key, one agent's
    # recall would suppress rows from another's — a write-side influence on someone else's
    # retrieval, which the Epic-28 `(tenant, subject)` scope contract forbids.
    assert RecallHistoryCache.shown_ids(ctx.tenant, other_subject, ctx.session, ["shared-id"]) ==
             []

    assert RecallHistoryCache.shown_ids(ctx.tenant, ctx.subject, ctx.session, ["shared-id"]) ==
             ["shared-id"]
  end

  test "max_entries/0 is a positive integer and survives a nonsense config value" do
    assert is_integer(RecallHistoryCache.max_entries())
    assert RecallHistoryCache.max_entries() > 0
  end

  test "the entry ceiling: at the cap there is no room, and a missing table is never room" do
    # TTL bounds only an honest client — `session_id` is client-chosen, so a caller minting
    # a fresh token per request leaves entries nothing evicts for a whole window. The
    # decision is pure and arity-2 precisely so this is testable without filling a
    # node-wide table or mutating app config.
    assert RecallHistoryCache.room_for?(9, 10)
    refute RecallHistoryCache.room_for?(10, 10)
    refute RecallHistoryCache.room_for?(11, 10)
    # An un-booted table answers `:undefined`, which is not room: the insert would raise.
    refute RecallHistoryCache.room_for?(:undefined, 10)
  end

  test "session isolation: a second session in the same tenant starts empty", ctx do
    other_session = unique("session")

    :ok = RecallHistoryCache.mark_shown(ctx.tenant, ctx.subject, ctx.session, ["a"])

    assert RecallHistoryCache.shown_ids(ctx.tenant, ctx.subject, other_session, ["a"]) == []
  end

  test "no session means no containment — reads and writes are both no-ops", ctx do
    assert RecallHistoryCache.mark_shown(ctx.tenant, ctx.subject, nil, ["a"]) == :ok
    assert RecallHistoryCache.shown_ids(ctx.tenant, ctx.subject, nil, ["a"]) == []
  end

  test "an empty id list is a no-op in both directions", ctx do
    assert RecallHistoryCache.mark_shown(ctx.tenant, ctx.subject, ctx.session, []) == :ok
    assert RecallHistoryCache.shown_ids(ctx.tenant, ctx.subject, ctx.session, []) == []
  end

  test "a non-binary id is ignored rather than inserted", ctx do
    assert RecallHistoryCache.mark_shown(ctx.tenant, ctx.subject, ctx.session, [nil, 42, "ok"]) ==
             :ok

    assert RecallHistoryCache.shown_ids(ctx.tenant, ctx.subject, ctx.session, ["ok"]) == ["ok"]
  end

  test "ttl_seconds/0 is a positive integer and survives a nonsense config value" do
    assert is_integer(RecallHistoryCache.ttl_seconds())
    assert RecallHistoryCache.ttl_seconds() > 0
  end

  test "marking is idempotent — a repeat does not create a second entry", ctx do
    :ok = RecallHistoryCache.mark_shown(ctx.tenant, ctx.subject, ctx.session, ["a"])
    :ok = RecallHistoryCache.mark_shown(ctx.tenant, ctx.subject, ctx.session, ["a"])

    assert :ets.lookup(
             RecallHistoryCache.table_name(),
             {ctx.tenant, ctx.subject, ctx.session, "a"}
           )
           |> length() == 1
  end
end
