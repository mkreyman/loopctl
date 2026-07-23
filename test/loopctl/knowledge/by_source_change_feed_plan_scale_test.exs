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
    # `config/test.exs` points EVERY injected collaborator at a Mox mock for the whole
    # test env, and this module does not `use Loopctl.DataCase`, so nothing has stubbed
    # them. Any call reaching an unstubbed mock raises `Mox.UnexpectedCallError` in the
    # nightly scale job. Install the SAME permissive default set DataCase gives every
    # other test, rather than hand-picking one mock at a time: the narrow
    # `stub_embedding_read_path/0` left `MockEmbeddingConcurrency` unstubbed, which is
    # exactly how the nightly broke. `stub_all_defaults/0` is a superset of it and the
    # single source of truth, so a mock added to DataCase is covered here automatically.
    # The stub bodies are closures — an unused stub never executes, so this is inert for
    # collaborators a given scale file never touches.
    Loopctl.DataCase.stub_all_defaults()

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

  # AC-27.9b.2 / review item-3: the BY-TAG deep page is the literal #175 incident path
  # this story fixes, and `index_keyset_query` is a DISTINCT query from 27.9a's
  # keyset_query (it forces `status = :published` + the project OR-clause), so we pin its
  # tag-filtered plan HERE on the actual request-path query. Same honest tags-shape
  # profile as 27.9a: the tags GIN bounds the scan (no btree can serve both array
  # containment AND the (inserted_at, id) order), so we assert no unbounded Seq Scan, the
  # selective tags GIN drives it, and the scan stays bounded by tag selectivity.
  test "by-tag deep page on index_keyset_query is bounded by the tags GIN at prod scale",
       %{tenant: tenant} do
    unboxed(fn ->
      published_count =
        AdminRepo.one(
          from(a in Article,
            where: a.tenant_id == ^tenant.id and a.status == :published,
            select: count(a.id)
          )
        )

      deep_offset = trunc(published_count * 0.9)

      deep =
        AdminRepo.one(
          from(a in Article,
            where: a.tenant_id == ^tenant.id and a.status == :published,
            order_by: [asc: a.inserted_at, asc: a.id],
            offset: ^deep_offset,
            limit: 1,
            select: %{id: a.id, inserted_at: a.inserted_at}
          )
        )

      assert deep, "expected a deep published row at offset #{deep_offset}"

      cursor = {deep.inserted_at, deep.id}

      query =
        Knowledge.index_keyset_query(tenant.id, tags: ["scale-tag-7"], cursor: cursor, limit: 21)

      assert :ok = PlanAssertions.refute_seq_scan(query),
             "by-tag index_keyset_query must not Seq-Scan the corpus at prod scale"

      assert :ok = PlanAssertions.assert_index_used(query, "articles_tags_index"),
             "by-tag index_keyset_query must be bounded by the selective tags GIN"

      max_bounded = div(ScaleSeed.prod_article_floor(), 8)

      assert :ok = PlanAssertions.assert_scan_rows_below(query, max_bounded),
             "by-tag index_keyset_query must stay bounded by tag selectivity, not scan the corpus"
    end)
  end

  test "change-feed keyset deep page is a multi-partition Merge Append, no Seq/Bitmap",
       %{tenant: tenant} do
    unboxed(fn ->
      total =
        AdminRepo.one(from(a in AuditLog, where: a.tenant_id == ^tenant.id, select: count(a.id)))

      assert total > 0, "expected seeded audit_log rows"

      # Confirm the seed actually straddles ≥2 monthly partitions (the prod shape). The
      # rows span the current month and the next (ScaleSeed.seed_changes/2), so distinct
      # year-months > 1.
      distinct_months =
        AdminRepo.one(
          from(a in AuditLog,
            where: a.tenant_id == ^tenant.id,
            select: count(fragment("DISTINCT date_trunc('month', ?)", a.inserted_at))
          )
        )

      assert distinct_months >= 2,
             "seed must span ≥2 monthly partitions for a real Merge Append (got #{distinct_months})"

      # Pick a cursor at the LAST row of the FIRST (current) month, so the forward keyset
      # seek `(inserted_at, id) > cursor` includes the current-month tail AND all of the
      # next month — forcing a deep page whose Merge Append spans BOTH partitions (the
      # prod multi-partition shape), not a single-partition shortcut.
      {:ok, month_start} =
        DateTime.new(
          Date.new!(DateTime.utc_now().year, DateTime.utc_now().month, 1),
          ~T[00:00:00]
        )

      {next_year, next_month} =
        if month_start.month == 12,
          do: {month_start.year + 1, 1},
          else: {month_start.year, month_start.month + 1}

      {:ok, next_month_start} = DateTime.new(Date.new!(next_year, next_month, 1), ~T[00:00:00])

      boundary =
        AdminRepo.one(
          from(a in AuditLog,
            where: a.tenant_id == ^tenant.id and a.inserted_at < ^next_month_start,
            order_by: [desc: a.inserted_at, desc: a.id],
            limit: 1,
            select: %{id: a.id, inserted_at: a.inserted_at}
          )
        )

      assert boundary, "expected a current-month row before the partition boundary"

      cursor = {boundary.inserted_at, boundary.id}

      # The EXACT request-path query, for a boundary-straddling deep cursor.
      query =
        Audit.changes_keyset_query(tenant.id, DateTime.from_unix!(0),
          cursor: cursor,
          limit: 1001
        )

      # Multi-partition guard (review item-2): the page must span ≥2 partitions via
      # per-partition Index Scans under an ordered combiner (Merge Append, or Append +
      # Incremental Sort — the planner's empirical choice here) — the prod shape, so
      # refute_full_scan_audit isn't vacuous on a single-partition shortcut.
      assert :ok = PlanAssertions.assert_ordered_multi_partition_scan(query, 2),
             "deep change-feed page must be an ordered scan over ≥2 audit_log partitions"

      # Tightened (review item-4): forbid Bitmap too (refute_full_scan_audit), proving
      # per-partition ordered Index Scans (an incremental sort resolves the id tie-break)
      # — no Seq Scan, no Bitmap over the corpus.
      assert :ok = PlanAssertions.refute_full_scan_audit(query),
             "change-feed keyset deep page must be per-partition index scans over audit_log " <>
               "(no Seq Scan, no Bitmap) at prod scale"

      {elapsed_us, _rows} = :timer.tc(fn -> AdminRepo.all(query) end)
      elapsed_ms = div(elapsed_us, 1000)

      assert elapsed_ms < @heavy_read_statement_timeout_ms,
             "deep change-feed page took #{elapsed_ms}ms, expected < #{@heavy_read_statement_timeout_ms}ms"
    end)
  end
end
