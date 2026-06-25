defmodule Loopctl.Knowledge.KeysetPlanScaleTest do
  @moduledoc """
  US-27.9a / AC-27.9a.2 + TC-27.9a.4: prove the article-list KEYSET seek for a
  DEEP page is index-backed at >= prod scale via the new
  `(tenant_id, inserted_at, id)` composite index — no Seq Scan / full-corpus read.

  Unlike the suggested_links plan test (HNSW), the keyset seek is a plain btree
  index scan, so this asserts `PlanAssertions.refute_full_scan/1` (no full-corpus
  node), NOT `assert_hnsw_index/1`.

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

        ScaleSeed.seed(t.id, count: ScaleSeed.prod_article_floor(), link_density: 5)
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

  test "keyset seek for a DEEP page is index-backed (no Seq Scan) at prod scale",
       %{tenant: tenant} do
    unboxed(fn ->
      # Pick a position deep in (inserted_at ASC, id ASC) order — ~90% through the
      # corpus — so the seek is a genuinely late page, the #148 offset-drift /
      # deep-page-cost scenario the index must serve.
      deep_offset = trunc(ScaleSeed.prod_article_floor() * 0.9)

      deep =
        AdminRepo.one(
          from(a in Article,
            where: a.tenant_id == ^tenant.id,
            order_by: [asc: a.inserted_at, asc: a.id],
            offset: ^deep_offset,
            limit: 1,
            select: %{id: a.id, inserted_at: a.inserted_at}
          )
        )

      assert deep, "expected a deep row at offset #{deep_offset}"

      # Build the EXACT request-path query list_keyset/2 runs for that deep cursor.
      query =
        Knowledge.keyset_query(tenant.id,
          status: :published,
          cursor: {deep.inserted_at, deep.id},
          limit: 21
        )

      # AC-27.9a.2 / TC-27.9a.4: the planner's NATURAL choice (no enable_seqscan=off)
      # at 80k must reach `articles` via the (tenant_id, inserted_at, id) btree —
      # never a Seq/Bitmap full-corpus scan.
      assert :ok = PlanAssertions.refute_full_scan(query)
    end)
  end
end
