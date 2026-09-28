defmodule Loopctl.Workers.RevokeExpiredDispatchesWorkerTest do
  @moduledoc """
  Epic 32 (scalability), US-32.1 — behavior-parity guard for the cross-tenant
  "revoke expired dispatches" Oban sweep.

  US-32.1 adds ONLY a partial index (`dispatches (expires_at) WHERE
  revoked_at IS NULL`) matching the sweep's predicate. Two guards cover it:

    * behavior parity — the worker revokes exactly the expired, non-revoked
      dispatches (and cascades to their api_keys), leaves active and
      already-revoked rows untouched, and does so cross-tenant by design;
    * index eligibility (AC-32.1.2) — the partial index is a valid single-column btree
      on `expires_at` whose predicate `revoked_at IS NULL` the worker's own query carries
      (`RevokeExpiredDispatchesWorker.expired_query/1`), read from `pg_index`. Which
      index the planner CHOOSES is not asserted: see the describe block below.

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
    # Eligibility, deterministically. Which index the planner CHOOSES is not asserted here:
    # the composite `(tenant_id, expires_at)` index can serve `expires_at <` too, as a full
    # index scan, and the choice moves with the rows other async tests leave in the shared
    # table (a plan pinned to one index failed at random for that reason). What makes the
    # partial index usable is that it is a valid single-column btree on `expires_at` whose
    # predicate the sweep's own WHERE clause carries; each half is asserted below, the
    # predicate against the query `RevokeExpiredDispatchesWorker` really runs.
    test "is a valid btree on expires_at whose predicate the sweep's own query carries" do
      %{rows: [[valid?, keys, key_count, method, table, predicate]]} =
        AdminRepo.query!("""
        SELECT i.indisvalid, pg_get_indexdef(i.indexrelid, 1, true), i.indnkeyatts,
               am.amname, i.indrelid::regclass::text, pg_get_expr(i.indpred, i.indrelid)
        FROM pg_index i
        JOIN pg_class c ON c.oid = i.indexrelid
        JOIN pg_am am ON am.oid = c.relam
        WHERE i.indexrelid = 'dispatches_expires_at_active_index'::regclass
        """)

      # An interrupted CONCURRENTLY build leaves an INVALID index with the same definition.
      assert valid?
      assert {keys, key_count, method, table} == {"expires_at", 1, "btree", "dispatches"}
      assert predicate == "(revoked_at IS NULL)"

      {sql, _params} =
        SQL.to_sql(
          :all,
          AdminRepo,
          RevokeExpiredDispatchesWorker.expired_query(DateTime.utc_now())
        )

      assert sql =~ ~s|"revoked_at" IS NULL|
      assert sql =~ ~r/"expires_at" < \$\d/
    end
  end
end
