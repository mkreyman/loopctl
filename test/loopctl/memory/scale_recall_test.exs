defmodule Loopctl.Memory.ScaleRecallTest do
  @moduledoc """
  US-28.5 terminal scale gate (TC-28.5.3 / AC-28.5.5).

  Seeds a large multi-subject memory corpus (≥ the prod floor) via
  `Loopctl.Memory.ScaleSeed`, with ONE distinguished subject (subject A) holding
  a small distinctive cluster of memories that are the genuine nearest neighbours
  to a known query embedding, then asserts subject A reliably recalls its OWN
  top-k out of the ~80k-row haystack.

  This proves the index-safe recall shape from US-28.2 (AC-28.2.3) does not
  STARVE a subject at scale: the inner ANN over-fetches a `(tenant_id,
  embedding IS NOT NULL, superseded_by IS NULL)` pool WITHOUT the subject filter
  (a selective `(tenant_id, subject_id)` btree there would defeat the pgvector
  HNSW index — #170/#172), and the SUBJECT scope is applied on the OUTER query
  over the materialised pool. If the HNSW ANN at prod scale failed to surface a
  needle-subject's distinctive cluster (0.06% of the corpus), or if the outer
  subject filter leaked another subject's rows, this test would fail.

  Note on pool sizing: in `config/test.exs` the over-fetch pool is deliberately
  tiny (`:max_vector_pool` = 6) so the cheap async under-fill tests stay cheap,
  so here `pool == k`. The proof is therefore the POSITIVE one the AC states —
  a needle subject reliably recalls its own top-k among a prod-sized haystack of
  many other subjects — not an interleave-defeat demonstration (which needs a
  prod-sized `pool > k` and would perturb the async suite's calibration). The
  cross-subject/cross-tenant EXCLUSION at scale is covered by asserting no other
  subject's row is ever returned.

  Seeds ~80k committed rows, so it is `@tag :scale` (excluded from `mix precommit`
  / plain `mix test`; run via `SCALE_TESTS=true mix test --only scale`).
  """
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Loopctl.AdminRepo
  alias Loopctl.Knowledge
  alias Loopctl.Memory
  alias Loopctl.Memory.ScaleSeed
  alias Loopctl.Memory.Scope
  alias Loopctl.Tenants.Tenant

  @moduletag :scale
  @moduletag timeout: :timer.minutes(30)

  defp unboxed(fun), do: Sandbox.unboxed_run(AdminRepo, fun)

  setup do
    # The embedding client runs inside a Task.async (Knowledge.generate_embedding),
    # so a from-context allowance wouldn't cover it — global mode (valid because
    # async: false) makes the stub reachable from that spawned process.
    Mox.set_mox_global()

    Mox.stub(Loopctl.MockEmbeddingClient, :generate_embedding, fn _tenant_id, _text ->
      {:ok, ScaleSeed.query_embedding()}
    end)

    {tenant, seed} =
      unboxed(fn ->
        slug = "mem-scale-#{:erlang.phash2(Ecto.UUID.generate())}"

        {:ok, t} =
          %Tenant{}
          |> Tenant.create_changeset(%{
            name: "Memory Scale #{slug}",
            slug: slug,
            email: "#{slug}@example.com",
            settings: %{},
            status: :active
          })
          |> AdminRepo.insert()

        {:ok, seed} = ScaleSeed.seed_multi_subject(t.id)
        {t, seed}
      end)

    Knowledge.reset_circuit_breaker(tenant.id)

    on_exit(fn ->
      try do
        unboxed(fn -> ScaleSeed.teardown(tenant.id) end)
      rescue
        _ -> :ok
      end
    end)

    {:ok, tenant: tenant, seed: seed}
  end

  test "a needle subject recalls its own top-k among a prod-sized multi-subject corpus (TC-28.5.3)",
       %{tenant: tenant, seed: seed} do
    # Seeded at least the prod floor, spread across many subjects.
    assert seed.total >= ScaleSeed.prod_memory_floor()

    k = 10
    scope = %Scope{tenant_id: tenant.id, subject_id: seed.subject_a, project_id: nil}

    %{results: results, meta: meta} =
      unboxed(fn -> Memory.recall(scope, query: "recall my distinctive facts", limit: k) end)

    # Full page — the subject was NOT starved by the subject-agnostic ANN pool.
    assert length(results) == k
    assert meta.underfilled == false
    # Semantic path (not the degraded ILIKE fallback): scores are floats.
    assert meta.fallback == false
    assert Enum.all?(results, fn {_m, score} -> is_float(score) end)

    returned_ids = Enum.map(results, fn {m, _score} -> m.id end)
    returned_subjects = results |> Enum.map(fn {m, _} -> m.subject_id end) |> Enum.uniq()

    # Every recalled row belongs to subject A — no other subject leaked through the
    # OUTER subject filter over the ANN pool (cross-subject isolation at scale).
    assert returned_subjects == [seed.subject_a]

    # And every recalled id is one of subject A's OWN seeded memories — the needle
    # cluster was surfaced from the ~80k-row haystack, not lost.
    a_id_set = MapSet.new(seed.subject_a_ids)
    assert Enum.all?(returned_ids, &MapSet.member?(a_id_set, &1))

    # A different subject in the SAME tenant, querying the SAME neighbourhood, gets
    # nothing — subject A's cluster is invisible cross-subject even at scale.
    other_scope = %Scope{tenant_id: tenant.id, subject_id: "scale-subject-0", project_id: nil}

    %{results: other_results} =
      unboxed(fn ->
        Memory.recall(other_scope, query: "recall my distinctive facts", limit: k)
      end)

    refute Enum.any?(other_results, fn {m, _} -> MapSet.member?(a_id_set, m.id) end)
  end
end
