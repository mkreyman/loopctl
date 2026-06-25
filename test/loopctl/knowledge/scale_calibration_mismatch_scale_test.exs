defmodule Loopctl.Knowledge.ScaleCalibrationMismatchScaleTest do
  @moduledoc """
  US-27.8 AC-27.8.3 / TC-27.8.3: the scale gate FAILS LOUDLY on miscalibration.

  A scale gate is only meaningful if it is honestly calibrated — seeded at/above the prod
  floor and running with prod's effective `hnsw.ef_search`. A sub-floor seed or a divergent
  ef_search would make an index-usage assertion false-GREEN (the planner Seq-Scans happily
  at toy scale; recall differs under a different ef_search). This test proves BOTH
  miscalibrations are caught with a clear error rather than silently passing:

    * **Sub-floor seed** — seeding BELOW `ScaleSeed.prod_article_floor/0` makes
      `PlanAssertions.assert_scale_floor!/1` RAISE a clear calibration error (it does NOT
      silently proceed as `assert_fresh_stats!/0` — non-empty + analyzed — would).

    * **ef_search mismatch (failure direction)** — the under-fill gate already asserts
      gate-vs-prod ef_search PARITY (`SHOW hnsw.ef_search` equal). Here we prove the FAILURE
      direction: a deliberately-mismatched effective value makes the same parity assertion
      RAISE — so a future prod `ALTER ROLE … SET hnsw.ef_search = N` that the gate didn't
      track cannot slip through green.

  The sub-floor case seeds only a HANDFUL of rows (it is asserting the FLOOR guard fires,
  not a plan), so it is fast; it is still `:scale_nightly` because it exercises the
  committed-corpus calibration machinery and must run on the scale gate, never the default
  async suite. Wired into the CI `scale_file` matrix (enforced by
  `scale_verification_runbook_test.exs`).
  """
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Loopctl.AdminRepo
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
        slug = "calib-#{:erlang.phash2(Ecto.UUID.generate())}"

        {:ok, t} =
          %Tenant{}
          |> Tenant.create_changeset(%{
            name: "Calib #{slug}",
            slug: slug,
            email: "#{slug}@example.com",
            settings: %{},
            status: :active
          })
          |> AdminRepo.insert()

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

  test "a SUB-FLOOR seed FAILS the calibration guard loudly (AC-27.8.3)", %{tenant: tenant} do
    floor = ScaleSeed.prod_article_floor()
    # Deliberately tiny — far below the floor — to model a half-scale (or unseeded) gate.
    sub_floor = 25

    unboxed(fn ->
      ScaleSeed.seed(tenant.id, count: sub_floor, link_density: 1)
    end)

    # The floor guard must RAISE with a clear, actionable calibration error that names the
    # actual-vs-required counts and points at the documented floor-bump step (AC-27.8.6) —
    # NOT pass the way assert_fresh_stats!/0 (non-empty + analyzed) would on this corpus.
    error =
      assert_raise ExUnit.AssertionError, fn ->
        unboxed(fn -> PlanAssertions.assert_scale_floor!(tenant.id) end)
      end

    assert error.message =~ "sub-floor seed"
    assert error.message =~ to_string(floor)
    assert error.message =~ "prod_article_floor"
    # And points at the AC-27.8.6 floor-bump step so the operator knows the remedy.
    assert error.message =~ "@prod_article_floor"

    # Contrast: assert_fresh_stats!/0 (the WEAKER precondition) is satisfied by this same
    # corpus — proving the floor guard catches a miscalibration the fresh-stats check can't.
    unboxed(fn ->
      AdminRepo.query!("ANALYZE articles")
      assert :ok = PlanAssertions.assert_fresh_stats!()
    end)
  end

  test "a REAL ef_search session divergence fails the gate-vs-prod parity assertion (failure direction, TC-27.8.3)" do
    # The under-fill gate asserts the EFFECTIVE `hnsw.ef_search` is identical on the gate
    # connection and a prod-shaped one (`SHOW hnsw.ef_search`). Here we drive the FAILURE
    # direction with a REAL pgvector GUC divergence end-to-end (not synthetic string literals,
    # review BA 4.1): inside ONE transaction we `SET LOCAL hnsw.ef_search = 80` and read it
    # back via `SHOW`, producing a genuinely-divergent effective value, then feed that REAL
    # read + a baseline read into the SAME shared `PlanAssertions.assert_ef_search_parity!/2`
    # the gate uses, and assert it raises. This proves the parity gate would actually catch a
    # prod `ALTER ROLE … SET hnsw.ef_search = N` drift — exercising the real GUC + SHOW path,
    # the real comparison, and the real message, with no duplicated local copy that could drift.

    # Baseline effective value on an untouched connection (pgvector default today, "40").
    baseline_ef =
      unboxed(fn ->
        AdminRepo.query!("SELECT '[1,2,3]'::vector")
        %{rows: [[v]]} = AdminRepo.query!("SHOW hnsw.ef_search")
        v
      end)

    # A REAL divergent read: `SET LOCAL` is TRANSACTION-scoped (auto-reverts at commit), and
    # all queries in one transaction share the connection, so the `SHOW` observes the override.
    diverged_ef =
      unboxed(fn ->
        {:ok, v} =
          AdminRepo.transaction(fn ->
            AdminRepo.query!("SET LOCAL hnsw.ef_search = 80")
            %{rows: [[val]]} = AdminRepo.query!("SHOW hnsw.ef_search")
            val
          end)

        v
      end)

    # The override actually took effect (real divergence, not a no-op) and differs from baseline.
    assert diverged_ef == "80"
    assert diverged_ef != baseline_ef

    # The SHARED parity assertion (the SAME one the under-fill gate drives in the success
    # direction) RAISES on the real divergent-vs-baseline reads — so a real prod/gate ef_search
    # drift cannot pass green.
    assert_raise ExUnit.AssertionError, ~r/ef_search diverged/, fn ->
      PlanAssertions.assert_ef_search_parity!(diverged_ef, baseline_ef)
    end

    # `SET LOCAL` reverted at the transaction boundary — a fresh read is back to baseline, so
    # this failure-direction probe left NO session pollution on the pooled connection, and the
    # matched reads pass (the success direction the real gate asserts).
    post_ef =
      unboxed(fn ->
        AdminRepo.query!("SELECT '[1,2,3]'::vector")
        %{rows: [[v]]} = AdminRepo.query!("SHOW hnsw.ef_search")
        v
      end)

    assert post_ef == baseline_ef
    assert :ok = PlanAssertions.assert_ef_search_parity!(post_ef, baseline_ef)
  end
end
