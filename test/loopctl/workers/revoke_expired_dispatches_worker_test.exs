defmodule Loopctl.Workers.RevokeExpiredDispatchesWorkerTest do
  @moduledoc """
  Epic 32 (scalability), US-32.1 — behavior-parity guard for the cross-tenant
  "revoke expired dispatches" Oban sweep.

  US-32.1 adds ONLY a partial index (`dispatches (expires_at) WHERE
  revoked_at IS NULL`) matching the sweep's predicate. Two guards cover it:

    * behavior parity — the worker revokes exactly the expired, non-revoked
      dispatches (and cascades to their api_keys), leaves active and
      already-revoked rows untouched, and does so cross-tenant by design;
    * index usage (AC-32.1.2) — `EXPLAIN` of the worker's exact predicate plans
      as an Index Scan on the new partial index, never a Seq Scan. Index choice
      is a planner concern (cost-based, sensitive to table size), so this guard
      makes the assertion deterministic at any scale rather than relying on
      out-of-band evidence — see the describe block below for the how/why.

  Dispatches are created through the real `Loopctl.Dispatches.create_dispatch/3`
  API (which mints + links a real api_key) so the cascade parity is exercised,
  then their `expires_at`/`revoked_at` are forced into the past with AdminRepo —
  `create_dispatch/3` clamps `expires_in` to a 60s MINIMUM and so cannot itself
  produce an already-expired or pre-revoked dispatch.
  """

  use Loopctl.DataCase, async: true

  import Ecto.Query
  import Loopctl.Fixtures

  alias Ecto.Adapters.SQL
  alias Loopctl.AdminRepo
  alias Loopctl.Auth.ApiKey
  alias Loopctl.Dispatches
  alias Loopctl.Dispatches.Dispatch
  alias Loopctl.Workers.RevokeExpiredDispatchesWorker

  defp create_dispatch(tenant) do
    agent = fixture(:agent, tenant_id: tenant.id)

    {:ok, %{dispatch: dispatch}} =
      Dispatches.create_dispatch(tenant.id, %{role: :agent, agent_id: agent.id})

    dispatch
  end

  defp force(dispatch_id, fields) do
    {1, _} =
      from(d in Dispatch, where: d.id == ^dispatch_id)
      |> AdminRepo.update_all(set: fields)

    AdminRepo.get!(Dispatch, dispatch_id)
  end

  describe "perform/1 — revoke sweep" do
    test "revokes expired non-revoked dispatches and cascades to their api_keys, leaving active ones untouched" do
      # Two tenants — the sweep is cross-tenant by design, so it must revoke based
      # on expiry/revoked state regardless of which tenant a dispatch belongs to.
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)

      now = DateTime.utc_now()
      past = DateTime.add(now, -120, :second)
      future = DateTime.add(now, 3_600, :second)

      # EXPIRED + non-revoked in tenant A → should be revoked (and its api_key too).
      expired_a = create_dispatch(tenant_a)
      expired_a = force(expired_a.id, expires_at: past)

      # EXPIRED + non-revoked in tenant B → should also be revoked (cross-tenant).
      expired_b = create_dispatch(tenant_b)
      expired_b = force(expired_b.id, expires_at: past)

      # ACTIVE (future expiry) in tenant A → must stay untouched.
      active = create_dispatch(tenant_a)
      active = force(active.id, expires_at: future)

      assert :ok = RevokeExpiredDispatchesWorker.perform(%Oban.Job{args: %{}})

      # Expired dispatches revoked in both tenants.
      assert %Dispatch{revoked_at: %DateTime{}} = AdminRepo.get!(Dispatch, expired_a.id)
      assert %Dispatch{revoked_at: %DateTime{}} = AdminRepo.get!(Dispatch, expired_b.id)

      # Cascade parity: the linked api_keys of the expired dispatches are revoked.
      assert %ApiKey{revoked_at: %DateTime{}} = AdminRepo.get!(ApiKey, expired_a.api_key_id)
      assert %ApiKey{revoked_at: %DateTime{}} = AdminRepo.get!(ApiKey, expired_b.api_key_id)

      # Active dispatch and its api_key are left alone.
      assert %Dispatch{revoked_at: nil} = AdminRepo.get!(Dispatch, active.id)
      assert %ApiKey{revoked_at: nil} = AdminRepo.get!(ApiKey, active.api_key_id)
    end

    test "already-revoked dispatches are not touched again" do
      tenant = fixture(:tenant)

      now = DateTime.utc_now()
      past = DateTime.add(now, -120, :second)
      earlier_revoked_at = DateTime.add(now, -600, :second)

      # Expired AND already revoked (revoked_at set to an earlier timestamp).
      # The partial-index predicate `revoked_at IS NULL` excludes this row, and the
      # worker's `is_nil(revoked_at)` clause matches — so the sweep must skip it and
      # leave its earlier revoked_at unchanged.
      dispatch = create_dispatch(tenant)
      dispatch = force(dispatch.id, expires_at: past, revoked_at: earlier_revoked_at)

      assert :ok = RevokeExpiredDispatchesWorker.perform(%Oban.Job{args: %{}})

      reloaded = AdminRepo.get!(Dispatch, dispatch.id)
      assert DateTime.compare(reloaded.revoked_at, earlier_revoked_at) == :eq
    end
  end

  describe "partial index dispatches_expires_at_active_index (AC-32.1.2)" do
    test "the sweep's predicate plans as an Index Scan on the partial index, never a Seq Scan" do
      # Mirror the worker's EXACT sweep predicate (RevokeExpiredDispatchesWorker.perform/1):
      #   from(d in Dispatch, where: is_nil(d.revoked_at) and d.expires_at < ^now, ...)
      # so this EXPLAIN exercises the identical query shape that runs every 60s.
      now = DateTime.utc_now()

      query =
        from(d in Dispatch,
          where: is_nil(d.revoked_at) and d.expires_at < ^now,
          select: %{id: d.id, api_key_id: d.api_key_id}
        )

      # The test dispatches table is ~empty, so the DEFAULT planner correctly prefers
      # a Seq Scan (scanning a handful of pages beats an index descent) — a naturally
      # chosen Index Scan is only observable at scale. What AC-32.1.2 actually asserts
      # is that the index MATCHES the predicate and is USABLE by the planner; we prove
      # that deterministically at any table size by disabling seq scans for this
      # transaction and confirming the only remaining plan is an index scan on our
      # partial index (with the expected `expires_at <` Index Cond). Verified out of
      # band that at ~20k rows the DEFAULT planner picks this same index unprompted
      # (Index Scan, rows~86) — captured in the migration's verification note.
      #
      # `SET LOCAL` + the EXPLAIN must run on the SAME pinned connection, so both
      # go inside one `Repo.transaction`. `Ecto.Adapters.SQL.explain/3` checks out
      # its OWN connection and would miss the `SET LOCAL`, so we render the worker's
      # query to SQL and EXPLAIN it directly on this connection instead.
      {sql, params} = SQL.to_sql(:all, AdminRepo, query)

      {:ok, plan} =
        AdminRepo.transaction(fn ->
          AdminRepo.query!("SET LOCAL enable_seqscan = off")
          %{rows: rows} = AdminRepo.query!("EXPLAIN " <> sql, params)
          # Re-enable seq scans before this savepoint commits. AdminRepo is
          # sandboxed, so this transaction is a SAVEPOINT nested in the outer
          # sandbox transaction; a `SET LOCAL` in a subtransaction that releases
          # persists to the enclosing transaction (see config/test.exs:66-75).
          # Resetting here keeps the planner override scoped to the EXPLAIN.
          AdminRepo.query!("RESET enable_seqscan")
          Enum.map_join(rows, "\n", fn [line] -> line end)
        end)

      assert plan =~ "Index Scan using dispatches_expires_at_active_index"
      assert plan =~ "Index Cond: (expires_at <"
      refute plan =~ "Seq Scan"
    end
  end
end
