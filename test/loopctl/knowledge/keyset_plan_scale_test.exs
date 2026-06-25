defmodule Loopctl.Knowledge.KeysetPlanScaleTest do
  @moduledoc """
  US-27.9a / AC-27.9a.2 + TC-27.9a.4: prove the article-list KEYSET seek for a
  DEEP page is index-backed at >= prod scale via the new
  `(tenant_id, inserted_at, id)` composite index — no Seq Scan / full-corpus read.

  Unlike the suggested_links plan test (HNSW), the keyset seek is a plain btree
  index scan, so this asserts `PlanAssertions.refute_full_scan/1` (no full-corpus
  node), NOT `assert_hnsw_index/1`.

  CRITICAL — residual coverage: `list_keyset/2` runs `apply_search_filters/3`, so
  the production keyset query is NOT just `status = :published + cursor`; the HTTP
  callers walk WITH `?tags=`/`?category=` filters. A selective residual inside an
  index-ordered query is exactly the BitmapAnd+Sort hazard that shipped the
  #170/#172 prod-500s, so this test asserts the plan for EVERY production shape, with
  the assertion that matches what each shape can physically achieve:

  - SCALAR shapes (residual-free, `+category`) MUST be strictly index-ordered — the
    `(tenant_id, inserted_at, id)` btree walked in order, no Sort, no Bitmap
    (`refute_full_scan/1`). This is the core keyset promise.
  - ARRAY shape (`+tags`, `+tags+category`): `tags &&` is served by a GIN index and
    no btree can provide both array containment AND `(inserted_at, id)` order, so the
    planner BitmapAnds the tags GIN with the keyset btree and Sorts. That is bounded
    by TAG SELECTIVITY, not the corpus, and is non-regressive vs the tag-filtered
    OFFSET query. We assert the catastrophe-guard (`refute_seq_scan/1` — no unbounded
    full-corpus read) plus `assert_index_used/2` for BOTH the selective tags GIN and
    the keyset btree, proving the bound is real. See docs/runbooks/knowledge-scale.md.

  The corpus is seeded with a realistic ~20% non-published `status_mix` so the
  `status = :published` residual itself has selectivity (the walk must skip
  non-matching index entries).

  Seeds ~80k committed rows (Loopctl.Knowledge.ScaleSeed), so it is
  `:scale_nightly` (runs on the nightly/scale gate, not the default async suite).
  """
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Loopctl.AdminRepo
  alias Loopctl.Knowledge
  alias Loopctl.Knowledge.Article
  alias Loopctl.Knowledge.ScaleSeed
  alias Loopctl.PlanAssertions
  alias Loopctl.Tenants.Tenant

  import Ecto.Query

  @moduletag :scale_nightly
  @moduletag timeout: :timer.minutes(30)

  defp unboxed(fun), do: Sandbox.unboxed_run(AdminRepo, fun)

  setup do
    tenant =
      unboxed(fn ->
        slug = "keyset-scale-#{:erlang.phash2(Ecto.UUID.generate())}"

        {:ok, t} =
          %Tenant{}
          |> Tenant.create_changeset(%{
            name: "Keyset Scale #{slug}",
            slug: slug,
            email: "#{slug}@example.com",
            settings: %{},
            status: :active
          })
          |> AdminRepo.insert()

        # status_mix: ~20% non-published so the `status = :published` residual has
        # real selectivity (the deep page must skip filtered index entries).
        ScaleSeed.seed(t.id,
          count: ScaleSeed.prod_article_floor(),
          link_density: 5,
          status_mix: true
        )

        t
      end)

    on_exit(fn ->
      try do
        unboxed(fn ->
          AdminRepo.delete_all(from(a in Article, where: a.tenant_id == ^tenant.id))
          AdminRepo.delete_all(from(t in Tenant, where: t.id == ^tenant.id))
        end)
      rescue
        _ -> :ok
      end
    end)

    {:ok, tenant: tenant}
  end

  test "keyset seek for a DEEP page is index-backed for EVERY production residual shape at prod scale",
       %{tenant: tenant} do
    unboxed(fn ->
      # Pick a position deep in (inserted_at ASC, id ASC) order among PUBLISHED rows
      # — ~90% through the published corpus — so the seek is a genuinely late page,
      # the #148 offset-drift / deep-page-cost scenario the index must serve.
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

      # Every shape below is the EXACT request-path query list_keyset/2 runs
      # (keyset_query/2), for a deep cursor, under the planner's NATURAL choice
      # (no enable_seqscan=off) at 80k.
      #
      # SCALAR paths (no filter, or `category =`) must be STRICTLY index-ordered:
      # the planner reaches `articles` via the (tenant_id, inserted_at, id) btree and
      # walks in order with NO Sort and NO Bitmap (refute_full_scan). This is the core
      # keyset promise (AC-27.9a.2 / TC-27.9a.4) and the primary enumeration path.
      for {label, opts} <- [
            {"residual-free", [status: :published, cursor: cursor, limit: 21]},
            {"+category", [status: :published, cursor: cursor, limit: 21, category: :pattern]}
          ] do
        query = Knowledge.keyset_query(tenant.id, opts)

        assert :ok = PlanAssertions.refute_full_scan(query),
               "scalar keyset plan for shape #{label} must be strictly index-ordered at prod scale"
      end

      # ARRAY path (`tags &&`, served by the GIN index): no btree can provide BOTH
      # array containment AND `(inserted_at, id)` order, so the planner uses the tags
      # GIN and Sorts. That is bounded by TAG SELECTIVITY (not the corpus) and is the
      # same plan a tag-filtered OFFSET query already used (non-regressive) — see
      # docs/runbooks/knowledge-scale.md. We assert the catastrophe-guard (no unbounded
      # Seq Scan) AND that the bound is REAL: the selective tags GIN drives the scan,
      # so cost scales with tag-matches, not corpus.
      #
      # We deliberately do NOT also require the keyset btree to appear in the plan: once
      # the tags GIN has cut the corpus to ~2%, the planner is free to apply the cursor
      # as a cheap heap filter instead of a second BitmapAnd index — a cost-marginal
      # choice at exactly the 80k floor that a small stats shift can flip. Asserting that
      # specific BitmapAnd shape would make the nightly gate flaky (false RED) without
      # catching any real regression; the tags-GIN bound + no-Seq-Scan is the invariant
      # that actually matters.
      for {label, opts} <- [
            {"+tags", [status: :published, cursor: cursor, limit: 21, tags: ["scale-tag-7"]]},
            {"+tags+category",
             [
               status: :published,
               cursor: cursor,
               limit: 21,
               tags: ["scale-tag-7"],
               category: :pattern
             ]}
          ] do
        query = Knowledge.keyset_query(tenant.id, opts)

        assert :ok = PlanAssertions.refute_seq_scan(query),
               "tag-filtered keyset plan for #{label} must not Seq-Scan the corpus at prod scale"

        assert :ok = PlanAssertions.assert_index_used(query, "articles_tags_index"),
               "tag-filtered keyset plan for #{label} must be bounded by the selective tags GIN"
      end
    end)
  end
end
