defmodule Loopctl.Knowledge.RemediationMatrixScaleTest do
  @moduledoc """
  US-27.13 remediation-matrix scale gate (AC-27.13.1/.2/.4/.5): ONE calibrated,
  certified census that aggregates every per-endpoint vector/enumeration plan gate
  into a single pass/fail matrix WITH calibration provenance.

  This closes the detect→fix seam (BA review C1): the US-27.6b/27.7a/27.8/27.9a/27.9b
  gates already PROVE each endpoint is index-correct at >= prod scale, making the
  remediation work-list empty. AC-27.13.4 makes that all-green outcome VALID only when
  the matrix records its calibration provenance (seed count >= `prod_article_floor` AND
  the effective `hnsw.ef_search`) and REJECTS an uncalibrated run as INVALID rather than
  rubber-stamping it green. The live-build confirmation on `suggested_links`
  (AC-27.13.4b) is run separately against prod per the US-27.5 runbook — not here.

  Three tests:

    * **Test A (happy census)** — build the matrix against the committed 80k corpus,
      `IO.puts` the JSON (CI records it as the AC-27.13.1 work-list), and assert it is
      calibrated, work-list-empty, certified, every asserted endpoint passed, and the
      census is COMPLETE (no endpoint silently dropped).
    * **Test B (anti-rubber-stamp / INVALID path)** — prove a calibration failure yields
      `certified? == false`, NOT a green pass, by driving the REAL `certified?/1` with an
      injected sub-floor / nil-ef calibration map (mirroring how
      `scale_calibration_mismatch_scale_test.exs` drives the shared assertion in both
      directions). No sub-floor reseed (too slow).
    * **Test C (tenant isolation)** — a SECOND tiny tenant's rows do not bleed into the
      first tenant's `seed_count` (the census's calibration count is tenant-scoped).

  Seeds ~80k committed rows via `Loopctl.Knowledge.ScaleSeed`, so it is `:scale_nightly`
  (nightly/scale gate, NOT the default async suite) and is wired into
  `.github/workflows/ci.yml`'s `scale_file` matrix (enforced by
  `scale_verification_runbook_test.exs`).
  """
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Loopctl.AdminRepo
  alias Loopctl.Knowledge.Article
  alias Loopctl.Knowledge.ScaleSeed
  alias Loopctl.RemediationMatrix
  alias Loopctl.Tenants.Tenant

  import Ecto.Query

  @moduletag :scale_nightly
  @moduletag timeout: :timer.minutes(30)

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
        slug = "remediation-matrix-scale-#{:erlang.phash2(Ecto.UUID.generate())}"

        {:ok, t} =
          %Tenant{}
          |> Tenant.create_changeset(%{
            name: "Remediation Matrix Scale #{slug}",
            slug: slug,
            email: "#{slug}@example.com",
            settings: %{},
            status: :active
          })
          |> AdminRepo.insert()

        # link_density: 5 (the prod-floor default) — enough links for the suggested_links
        # anti-join + distant_pairs to be real. `status_mix: true` interleaves ~20%
        # non-published rows so the enumeration endpoints' `status = :published` residual has
        # REAL selectivity (matching keyset_plan_scale_test.exs's corpus, not an all-published
        # no-op — architect review F1); the vector endpoints still see ~64k published embedded
        # rows, ample for the HNSW path. More prod-representative for the whole census.
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

  test "the remediation matrix is calibrated, complete, work-list-empty, and certified at prod scale",
       %{tenant: tenant} do
    matrix = unboxed(fn -> RemediationMatrix.build(tenant.id) end)

    # CI records the census as the AC-27.13.1 remediation work-list (the matrix IS the
    # work-list). Print BEFORE asserting so a RED endpoint's reason is in the log.
    json = RemediationMatrix.to_json(matrix)
    IO.puts("\n=== US-27.13 remediation matrix ===\n" <> json)

    # The rendered census is valid JSON that round-trips to the recorded shape (exercises the
    # pretty-printer across every result/coverage variant — engineer review LOW-2).
    decoded = JSON.decode!(json)
    assert is_map(decoded["calibration"]) and is_list(decoded["endpoints"])
    assert decoded["certified"] == true and decoded["work_list"] == []

    # Unit assertion: the pretty-printer handles all result variants, including :fail with
    # tricky reason strings (newlines, quotes, braces). Synthetic matrix needed since the
    # real gate only produces green/delegated.
    synthetic_fail_reason =
      "plan rejected: EXPLAIN { plan:\n  \"node\": \"Seq Scan\",\n  \"rows\": 80000 }\n quote: \""

    synthetic_matrix = %{
      calibration: matrix.calibration,
      endpoints: [
        %{
          name: "test_endpoint",
          dimension: :vector,
          coverage: :asserted,
          result: {:fail, synthetic_fail_reason}
        }
      ],
      certified?: false,
      work_list: ["test_endpoint"]
    }

    synthetic_json = RemediationMatrix.to_json(synthetic_matrix)
    synthetic_decoded = JSON.decode!(synthetic_json)
    assert is_map(synthetic_decoded["calibration"])
    assert is_list(synthetic_decoded["endpoints"])

    assert Enum.any?(synthetic_decoded["endpoints"], fn ep ->
             ep["name"] == "test_endpoint" and ep["result"]["status"] == "fail" and
               ep["result"]["reason"] =~ "Seq Scan"
           end)

    # AC-27.13.4a: calibration provenance — seed >= prod floor AND a readable ef_search.
    assert matrix.calibration.calibrated? == true,
           "matrix must be calibrated (seed >= prod_floor AND ef_search read): " <>
             inspect(matrix.calibration)

    assert matrix.calibration.seed_count >= matrix.calibration.prod_floor
    assert is_binary(matrix.calibration.effective_ef_search)

    # AC-27.13.1/.2: the work-list (asserted endpoints whose plan assertion RAISED) is
    # empty — every endpoint the gate proves is index-correct at scale.
    assert matrix.work_list == [],
           "remediation work-list must be empty; RED endpoints: #{inspect(matrix.work_list)}"

    # AC-27.13.4: certified == calibrated AND work-list empty.
    assert matrix.certified? == true

    # Every ASSERTED endpoint passed (delegated ones are :delegated, not :pass).
    for ep <- matrix.endpoints, ep.coverage == :asserted do
      assert ep.result == :pass,
             "asserted endpoint #{ep.name} must pass; got #{inspect(ep.result)}"
    end

    # The two delegated endpoints are present, honestly marked :delegated (NOT :pass) —
    # covered by their own dedicated gate, visible here for COMPLETE coverage.
    delegated = Enum.filter(matrix.endpoints, &match?({:delegated, _}, &1.coverage))
    assert length(delegated) == 2

    for ep <- delegated do
      assert ep.result == :delegated,
             "delegated endpoint #{ep.name} must be :delegated (never falsely :pass)"
    end

    # COMPLETENESS (AC-27.13.1): the census must cover the canonical endpoint set
    # EXACTLY — a silently-dropped endpoint (gap in coverage) fails the test.
    actual_names = matrix.endpoints |> Enum.map(& &1.name) |> MapSet.new()
    expected_names = MapSet.new(RemediationMatrix.canonical_endpoint_names())

    assert MapSet.equal?(actual_names, expected_names),
           "census coverage drifted from the canonical set.\n" <>
             "Missing: #{inspect(MapSet.to_list(MapSet.difference(expected_names, actual_names)))}\n" <>
             "Unexpected: #{inspect(MapSet.to_list(MapSet.difference(actual_names, expected_names)))}"
  end

  test "an UNCALIBRATED matrix is REJECTED as invalid (certified? == false), not rubber-stamped green",
       %{tenant: tenant} do
    # Build the REAL matrix (calibrated, certified) once.
    matrix = unboxed(fn -> RemediationMatrix.build(tenant.id) end)

    assert matrix.certified? == true,
           "precondition: the real matrix is certified before we inject miscalibration.\n" <>
             RemediationMatrix.to_json(matrix)

    floor = matrix.calibration.prod_floor

    # AC-27.13.4a — anti-rubber-stamp. Drive the SAME `certified?/1` the build uses
    # (not a re-implemented copy) with injected calibration failures, proving each
    # yields certified? == false EVEN THOUGH the work-list is empty. This is the
    # INVALID rejection that stops a mis-calibrated CI run certifying green.

    # 1. Sub-floor seed count (a half-scale / unseeded gate).
    sub_floor_cal = %{matrix.calibration | seed_count: floor - 1, calibrated?: false}

    refute RemediationMatrix.certified?(%{matrix | calibration: sub_floor_cal}),
           "a sub-floor matrix must be REJECTED as invalid, not certified green"

    # 2. No readable ef_search (uncalibrated GUC) — also INVALID.
    nil_ef_cal = %{matrix.calibration | effective_ef_search: nil, calibrated?: false}

    refute RemediationMatrix.certified?(%{matrix | calibration: nil_ef_cal}),
           "a matrix with no effective ef_search must be REJECTED as invalid"

    # Control: an empty work-list ALONE (still calibrated) IS certified — proving it's
    # the calibration that gates, and we didn't just break certified? unconditionally.
    assert RemediationMatrix.certified?(%{matrix | work_list: []})

    # And a calibrated matrix with a NON-empty work-list (a real RED endpoint) is also
    # rejected — certified? requires BOTH calibration AND a clean work-list.
    refute RemediationMatrix.certified?(%{matrix | work_list: ["suggested_links"]}),
           "a calibrated matrix with a RED endpoint must NOT certify"
  end

  test "the matrix calibration count is tenant-scoped (isolation, AC-27.13.5)", %{tenant: tenant} do
    # Seed a SECOND, tiny tenant. Its rows must NOT inflate the first tenant's seed_count
    # — the census's calibration count carries the tenant_id filter.
    other =
      unboxed(fn ->
        slug = "remediation-iso-#{:erlang.phash2(Ecto.UUID.generate())}"

        {:ok, t} =
          %Tenant{}
          |> Tenant.create_changeset(%{
            name: "Remediation Iso #{slug}",
            slug: slug,
            email: "#{slug}@example.com",
            settings: %{},
            status: :active
          })
          |> AdminRepo.insert()

        # A handful of rows — enough to prove the count is scoped, cheap to seed.
        ScaleSeed.seed(t.id, count: 25, link_density: 1)
        t
      end)

    on_exit(fn ->
      try do
        unboxed(fn ->
          AdminRepo.delete_all(from(a in Article, where: a.tenant_id == ^other.id))
          AdminRepo.delete_all(from(t in Tenant, where: t.id == ^other.id))
        end)
      rescue
        _ -> :ok
      end
    end)

    floor = ScaleSeed.prod_article_floor()

    # The first tenant's calibration count reflects ONLY its own ~80k corpus — the
    # second tenant's 25 rows are invisible to it.
    primary = unboxed(fn -> RemediationMatrix.build(tenant.id) end)
    assert primary.calibration.seed_count >= floor

    # The second tenant's count is its own 25 rows — NOT the first tenant's (it is far
    # below the floor), proving the count query is tenant-scoped, not corpus-wide.
    secondary = unboxed(fn -> RemediationMatrix.build(other.id) end)
    assert secondary.calibration.seed_count == 25
    assert secondary.calibration.seed_count < floor

    # A sub-floor tenant is (correctly) NOT calibrated, so NOT certified — the gate
    # would refuse to rubber-stamp a run against that tenant.
    assert secondary.calibration.calibrated? == false
    assert secondary.certified? == false
  end

  test "calibration derivation logic covers all four corners (F3 / no-deferrals)" do
    # F3: the nil-ef case must be testable independently. Unit test the extracted
    # pure function `calibrated_from_values?/3` for all four corners.
    floor = ScaleSeed.prod_article_floor()
    sub_floor = floor - 1
    ef_readable = "40"
    ef_nil = nil

    # Corner 1: floor + readable ef → calibrated
    assert RemediationMatrix.calibrated_from_values?(floor, floor, ef_readable) == true

    # Corner 2: floor + nil ef → NOT calibrated (ef check fails)
    assert RemediationMatrix.calibrated_from_values?(floor, floor, ef_nil) == false

    # Corner 3: sub-floor + readable ef → NOT calibrated (count check fails)
    assert RemediationMatrix.calibrated_from_values?(sub_floor, floor, ef_readable) == false

    # Corner 4: sub-floor + nil ef → NOT calibrated (both checks fail)
    assert RemediationMatrix.calibrated_from_values?(sub_floor, floor, ef_nil) == false
  end
end
