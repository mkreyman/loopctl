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

  test "an ef_search MISMATCH fails the gate-vs-prod parity assertion (failure direction, TC-27.8.3)" do
    # The under-fill gate asserts the EFFECTIVE `hnsw.ef_search` is identical on the gate
    # connection and a prod-shaped one (`SHOW hnsw.ef_search`). Here we drive the FAILURE
    # direction with two deliberately-divergent effective values and assert the SAME parity
    # form raises — so a real prod-vs-gate divergence cannot pass green.
    # Drive the SHARED `PlanAssertions.assert_ef_search_parity!/2` (the SAME assertion the
    # under-fill scale gate uses for the success direction) with two deliberately-divergent
    # effective values — so this failure path exercises the REAL comparison + message, not a
    # duplicated local copy that could silently drift from the real gate.
    assert_raise ExUnit.AssertionError, ~r/ef_search diverged/, fn ->
      PlanAssertions.assert_ef_search_parity!("40", "80")
    end

    # And it does NOT raise when they match (the success direction the real gate asserts).
    assert :ok = PlanAssertions.assert_ef_search_parity!("40", "40")
  end
end
