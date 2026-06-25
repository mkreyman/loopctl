defmodule Loopctl.Knowledge.BySourceChangeFeedPlanScaleTest do
  @moduledoc """
  US-27.9b / AC-27.9b.2 + TC-27.9b.2: prove the BY-SOURCE knowledge-index keyset and
  the CHANGE-FEED keyset are index-backed for a DEEP page at >= prod scale — no full
  Seq Scan / full-corpus read.

  Two enumeration surfaces, two index strategies (stated honestly per shape):

  - BY-SOURCE (`index_keyset_query` with `source_id =`): a SELECTIVE scalar equality.
    The `(tenant_id, source_id, inserted_at, id)` composite btree
    (`articles_tenant_source_inserted_id_idx`, US-27.9b migration) lets the planner
    seek straight to the source's rows and walk them in `(inserted_at, id)` order —
    strictly index-ordered, so `refute_full_scan/1` holds (no Sort, no Bitmap-over-
    corpus). The residual-free `(tenant_id, inserted_at, id)` shape (no source filter)
    is the US-27.9a keyset already proven; here we pin the by-source shape.

  - CHANGE-FEED (`changes_keyset_query` over the RANGE-partitioned `audit_log`): the
    keyset `(inserted_at, id)` seek with `tenant_id =` is served by the existing
    `(tenant_id, inserted_at)` btree (the `id` is the bounded tie-break recheck). We
    assert `refute_seq_scan_audit/1` (no unbounded full read of the partition) — a
    partitioned Index/Bitmap scan is fine; a Seq Scan over the corpus is the regression.

  Seeds ~80k committed articles (ScaleSeed.seed) + ~80k committed audit_log rows
  (ScaleSeed.seed_changes), so it is `:scale_nightly` (nightly/scale gate, not the
  default async suite). Wired into the CI scale matrix (scale_verification_runbook_test
  enforces every :scale_nightly file is listed).
  """
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Loopctl.AdminRepo
  alias Loopctl.Audit
  alias Loopctl.Audit.AuditLog
  alias Loopctl.Knowledge
  alias Loopctl.Knowledge.Article
  alias Loopctl.Knowledge.ScaleSeed
  alias Loopctl.PlanAssertions
  alias Loopctl.Tenants.Tenant

  import Ecto.Query

  @moduletag :scale_nightly
  @moduletag timeout: :timer.minutes(30)

  @heavy_read_statement_timeout_ms System.get_env("HEAVY_READ_STATEMENT_TIMEOUT_MS", "10000")
                                   |> String.to_integer()

  defp unboxed(fun), do: Sandbox.unboxed_run(AdminRepo, fun)

  setup do
    tenant =
      unboxed(fn ->
        slug = "bysrc-cf-scale-#{:erlang.phash2(Ecto.UUID.generate())}"

        {:ok, t} =
          %Tenant{}
          |> Tenant.create_changeset(%{
            name: "BySource/ChangeFeed Scale #{slug}",
            slug: slug,
            email: "#{slug}@example.com",
            settings: %{},
            status: :active
          })
          |> AdminRepo.insert()

        # Articles: status_mix so `status = :published` has selectivity; ScaleSeed now
        # seeds a selective source_id round-robined over 800 sources (~0.125%/source).
        ScaleSeed.seed(t.id,
          count: ScaleSeed.prod_article_floor(),
          link_density: 5,
          status_mix: true
        )

        # Audit rows for the change feed at the same prod floor.
        ScaleSeed.seed_changes(t.id, count: ScaleSeed.prod_article_floor())

        t
      end)

    on_exit(fn ->
      try do
        unboxed(fn ->
          AdminRepo.delete_all(from(a in Article, where: a.tenant_id == ^tenant.id))
          AdminRepo.delete_all(from(l in AuditLog, where: l.tenant_id == ^tenant.id))
          AdminRepo.delete_all(from(t in Tenant, where: t.id == ^tenant.id))
        end)
      rescue
        _ -> :ok
      end
    end)

    {:ok, tenant: tenant}
  end

  test "by-source keyset deep page is index-backed (composite index), no full scan",
       %{tenant: tenant} do
    unboxed(fn ->
      # Pick a real seeded source_id with many rows; bucket 7 is arbitrary but stable.
      source_id = ScaleSeed.source_id_for(tenant.id, 7)

      published_for_source =
        AdminRepo.one(
          from(a in Article,
            where:
              a.tenant_id == ^tenant.id and a.status == :published and a.source_id == ^source_id,
            select: count(a.id)
          )
        )

      assert published_for_source > 0,
             "expected seeded published rows for source #{source_id}"

      deep_offset = trunc(published_for_source * 0.9)

      deep =
        AdminRepo.one(
          from(a in Article,
            where:
              a.tenant_id == ^tenant.id and a.status == :published and a.source_id == ^source_id,
            order_by: [asc: a.inserted_at, asc: a.id],
            offset: ^deep_offset,
            limit: 1,
            select: %{id: a.id, inserted_at: a.inserted_at}
          )
        )

      assert deep, "expected a deep by-source row at offset #{deep_offset}"

      cursor = {deep.inserted_at, deep.id}

      query =
        Knowledge.index_keyset_query(tenant.id,
          source_type: ScaleSeed.scale_source_type(),
          source_id: source_id,
          cursor: cursor,
          limit: 21
        )

      assert :ok = PlanAssertions.refute_full_scan(query),
             "by-source keyset deep page must be strictly index-ordered via the composite index"

      # The scan must be BOUNDED by source selectivity, not the corpus.
      max_bounded = div(ScaleSeed.prod_article_floor(), 8)

      assert :ok = PlanAssertions.assert_scan_rows_below(query, max_bounded),
             "by-source keyset must stay bounded by source selectivity, not scan the corpus"

      # Timing: the deep by-source page must EXECUTE well under the heavy-read timeout.
      {elapsed_us, _rows} = :timer.tc(fn -> AdminRepo.all(query) end)
      elapsed_ms = div(elapsed_us, 1000)

      assert elapsed_ms < @heavy_read_statement_timeout_ms,
             "deep by-source page took #{elapsed_ms}ms, expected < #{@heavy_read_statement_timeout_ms}ms"
    end)
  end

  test "change-feed keyset deep page is index-backed (no Seq Scan over audit_log)",
       %{tenant: tenant} do
    unboxed(fn ->
      total =
        AdminRepo.one(from(a in AuditLog, where: a.tenant_id == ^tenant.id, select: count(a.id)))

      assert total > 0, "expected seeded audit_log rows"

      deep_offset = trunc(total * 0.9)

      deep =
        AdminRepo.one(
          from(a in AuditLog,
            where: a.tenant_id == ^tenant.id,
            order_by: [asc: a.inserted_at, asc: a.id],
            offset: ^deep_offset,
            limit: 1,
            select: %{id: a.id, inserted_at: a.inserted_at}
          )
        )

      assert deep, "expected a deep audit row at offset #{deep_offset}"

      cursor = {deep.inserted_at, deep.id}

      # The EXACT request-path query, for a deep cursor.
      query =
        Audit.changes_keyset_query(tenant.id, DateTime.from_unix!(0),
          cursor: cursor,
          limit: 1001
        )

      assert :ok = PlanAssertions.refute_seq_scan_audit(query),
             "change-feed keyset deep page must not Seq-Scan audit_log at prod scale"

      {elapsed_us, _rows} = :timer.tc(fn -> AdminRepo.all(query) end)
      elapsed_ms = div(elapsed_us, 1000)

      assert elapsed_ms < @heavy_read_statement_timeout_ms,
             "deep change-feed page took #{elapsed_ms}ms, expected < #{@heavy_read_statement_timeout_ms}ms"
    end)
  end
end
