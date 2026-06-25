defmodule Loopctl.Knowledge.CosineLintVsScaleGateScaleTest do
  @moduledoc """
  US-27.8 AC-27.8.5 (CRITICAL): the allowlist exempts the LINT, NOT the scale plan-gate.

  `Loopctl.Knowledge.CosineLintExceptions` lets a function (`do_distant_pairs/7`,
  `novelty_distance_query/4`) hand-roll a cosine `<=>` WITHOUT tripping the source lint
  (`Loopctl.Credo.Check.CosineQueryReintroduction`). This test proves that exemption is
  ONLY a source-location exemption — it grants NO protection from the plan gate:

    * A deliberately index-DEFEATING variant of an allowlisted-shape query (a
      `novelty`-flavored `MIN(embedding <=> $const)` with a corpus-scanning residual that
      makes the planner abandon the bounded path for a Seq Scan over the whole 80k corpus)
      STILL FAILS `PlanAssertions.refute_seq_scan/1` at scale. The allowlist did not save it.

  This is the anti-false-confidence guard the AC demands: nobody can hide an O(n) cosine
  regression behind the lint allowlist — the scale gate judges the SHAPE, independently of
  whether the SITE is lint-exempt.

  To keep the proof honest we ALSO show the genuine `novelty_distance_query/4` shape (the
  registered, bounded one) PASSES `refute_seq_scan/1` on the same corpus — so the test is
  not merely asserting "everything Seq-Scans at 80k" (which would be vacuous). The contrast
  is the point: same lint-exempt FUNCTION FAMILY, bounded shape passes, bad shape fails.

  Seeds ~80k committed rows, so `:scale_nightly`; wired into the CI `scale_file` matrix
  (enforced by `scale_verification_runbook_test.exs`).
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

  # The ~2% tag ScaleSeed stamps, so the genuine (bounded) novelty shape is selective.
  @prior_tag "scale-tag-3"

  defp unboxed(fun), do: Sandbox.unboxed_run(AdminRepo, fun)

  setup do
    tenant =
      unboxed(fn ->
        slug = "lint-vs-gate-#{:erlang.phash2(Ecto.UUID.generate())}"

        {:ok, t} =
          %Tenant{}
          |> Tenant.create_changeset(%{
            name: "Lint vs Gate #{slug}",
            slug: slug,
            email: "#{slug}@example.com",
            settings: %{},
            status: :active
          })
          |> AdminRepo.insert()

        ScaleSeed.seed(t.id, count: ScaleSeed.prod_article_floor(), link_density: 5)
        t
      end)

    unboxed(fn -> PlanAssertions.assert_scale_floor!(tenant.id) end)

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

  test "an index-defeating variant of an allowlisted (novelty) shape STILL fails the scale gate",
       %{tenant: tenant} do
    unboxed(fn ->
      idea_vec = ScaleSeed.embedding_for(0)

      # The GENUINE registered novelty shape — bounded by the ~2% prior tag. This is
      # lint-exempt (novelty_distance_query/4 is registered) AND index-bounded, so it
      # passes the gate. Establishes the non-vacuous baseline.
      good = Knowledge.novelty_distance_query(tenant.id, idea_vec, @prior_tag, nil)
      assert :ok = PlanAssertions.refute_seq_scan(good)

      # The INDEX-DEFEATING variant: the SAME cosine-`<=>`-to-a-`$const` FAMILY as the
      # registered novelty shape, but expressed as a `WHERE (embedding <=> $const) <
      # threshold` RANGE predicate over the whole tenant corpus. pgvector's HNSW serves an
      # `ORDER BY <=> LIMIT k` (the bounded MIN-rewrite the real novelty query uses) — it
      # CANNOT serve a `<=>` RANGE filter, so the planner must compute the distance per row
      # in a full-corpus `Seq Scan on articles` (verified at 80k: the exact #168/#172 rot the
      # gate exists to catch). If this site were registered in the allowlist it would be
      # LINT-clean, yet the plan gate must STILL reject it.
      bad =
        from(a in Article,
          where:
            a.tenant_id == ^tenant.id and a.status == :published and not is_nil(a.embedding) and
              fragment("(? <=> ?::vector) < ?", a.embedding, ^idea_vec, 0.9),
          select: count()
        )

      # The allowlist exempts the SITE from the lint; it does NOT exempt this SHAPE from the
      # plan gate. `refute_seq_scan/1` must RAISE on the full-corpus scan (its message names
      # the unbounded Seq Scan on `articles`).
      error =
        assert_raise ExUnit.AssertionError, fn ->
          PlanAssertions.refute_seq_scan(bad)
        end

      assert error.message =~ "Seq Scan on `articles`"
      assert error.message =~ "unbounded full-corpus read"
    end)
  end
end
