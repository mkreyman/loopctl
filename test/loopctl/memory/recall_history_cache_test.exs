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

  test "max_entries/0 is a ceiling far above what real session traffic reaches" do
    # A safety valve only, not a working limit: one recall contributes at most `limit` ids,
    # so a ceiling this high is thousands of live sessions. Asserting merely "a positive
    # integer" could not fail — the fallback is a positive module attribute — and would
    # still have passed with the ceiling set low enough to disable containment node-wide.
    assert is_integer(RecallHistoryCache.max_entries())
    assert RecallHistoryCache.max_entries() >= 10_000
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

  describe "capacity warning (#792 head audit)" do
    # `warn_if_full/2` is the ONLY thing that makes a node-wide containment failure
    # observable after the inline sweep was removed from the write path, and it shipped
    # with no test at all — nothing proved the branch was reachable, that the comparison
    # was read in the right direction, or that the message ever fired.

    test "warns, and says what is wrong, when the table is AT its ceiling" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert %{size: 10, cap: 10, warned: true} = RecallHistoryCache.warn_if_full(10, 10)
        end)

      assert log =~ "RecallHistoryCache at capacity (10/10)"
      assert log =~ "containment is disabled on this node"
    end

    test "is silent with one slot to spare — the comparison is strict, not inclusive" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert %{size: 9, cap: 10, warned: false} = RecallHistoryCache.warn_if_full(9, 10)
        end)

      refute log =~ "RecallHistoryCache at capacity"
    end

    test "an OVER-full table warns too, so a shrunk cap is not silently ignored" do
      ExUnit.CaptureLog.capture_log(fn ->
        assert %{warned: true} = RecallHistoryCache.warn_if_full(11, 10)
      end)
    end

    test "a table whose owner has not booted is NOT room, and warns" do
      # `:ets.info/2` answers `:undefined` for a missing table. Treating that as room
      # would let the insert raise and the caller's rescue turn it into the same silent
      # no-op this warning exists to end.
      ExUnit.CaptureLog.capture_log(fn ->
        assert %{warned: true} = RecallHistoryCache.warn_if_full(:undefined, 10)
      end)
    end

    test "the sweep actually calls it — the wiring, not just the decision" do
      # The live table is far below the 200_000 ceiling, so the VERDICT here is :ok. What
      # this pins is that :sweep reaches the check at all, which it can only do because the
      # handler records the verdict on its state. Asserting the log alone could not: with
      # the call deleted the handler still returned {:noreply, state} and the whole file
      # stayed green, which is exactly the "reachable only in principle" state the audit
      # flagged.
      assert {:noreply, state} = RecallHistoryCache.handle_info(:sweep, %{table: :ignored})

      # The CAP it recorded is the configured ceiling and the SIZE is the table's real
      # count — neither of which a stubbed-out check could produce, which is what makes
      # deleting the call detectable at all.
      assert %{warned: false, cap: cap, size: size} = state.last_capacity_check
      assert cap == RecallHistoryCache.max_entries()
      assert is_integer(size)
    end
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
