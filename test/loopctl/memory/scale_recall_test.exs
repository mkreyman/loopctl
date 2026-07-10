defmodule Loopctl.Memory.ScaleRecallTest do
  @moduledoc """
  US-28.5 terminal scale gate (TC-28.5.3 / AC-28.5.5).

  Seeds a large multi-subject memory corpus (≥ the prod floor) via
  `Loopctl.Memory.ScaleSeed`, shaped to reproduce the ONE failure AC-28.5.5
  guards: a subject whose relevant memories are NOT the globally-nearest rows —
  OTHER subjects' rows are nearer and DOMINATE the inner ANN pool — must still
  fill its own top-k. This is the cross-subject-dominance scenario the retired
  placeholder named ("a subject reliably recalls its own top-k WHEN OTHER
  SUBJECTS DOMINATE THE CORPUS"), plus the pool-depth / no-under-fill gate it
  promised.

  The corpus has three bands (see `Loopctl.Memory.ScaleSeed`): `decoy_count`
  FOREIGN "decoy" rows that are the GLOBAL nearest to the query (`decoy_count > k`,
  so a naive top-k of the subject-agnostic pool is 100% foreign), subject A's
  needle cluster ranked BEHIND the decoys but inside the over-fetch pool, and a
  far ~80k haystack. To fill A's k the recall must:

    * over-fetch a `(tenant_id, embedding IS NOT NULL, superseded_by IS NULL)`
      pool WITHOUT the subject filter (a selective `(tenant_id, subject_id)`
      btree there would defeat the pgvector HNSW index — #170/#172), then
    * apply the SUBJECT scope on the OUTER query, DISCARDING the nearer foreign
      decoys, and still return a FULL k with `meta.underfilled == false`.

  The gate can genuinely FAIL on the risk it guards: if the inner pool were
  subject-pre-filtered the pool probe would show A un-dominated (top-k not all
  foreign); if the pool were too shallow to hold A's k behind the decoys the
  recall would under-fill; if the outer filter leaked, another subject's rows
  would appear in A's result. A direct pool probe asserts A is dominated yet
  present with ≥ k rows, and a decoy-subject recall proves the nearer foreign
  rows are real — not an artifact of A being absent.

  ## Note on pool sizing (the regime this gate ACTUALLY runs under)

  This gate is `@tag :scale`, so it ONLY runs via `SCALE_TESTS=true mix test
  --only scale` (test_helper.exs includes `:scale` only when `SCALE_TESTS` is
  set). Under `SCALE_TESTS`, `config/test.exs` SKIPS the tiny-pool shrink
  (`:max_vector_pool = 6`) and leaves the PROD defaults (factor 5 / floor 100 /
  cap 500), so `pool_size(k = 10) = 50 |> max(100) |> min(500) |> max(10) = 100`.
  The regime is therefore `pool = 100 > k = 10` — a genuine over-fetch, NOT
  `pool == k`. (Recall is additionally bounded above by pgvector's
  `hnsw.ef_search ≈ 40 > k`, which caps how many pool rows the ANN surfaces; the
  corpus keeps the decoys + A's k inside that reach.) Because the pool exceeds k,
  the outer subject filter is doing real work — discarding nearer foreign rows —
  which is exactly what the interleave-defeat/dominance property needs and what
  this gate now demonstrates.

  Seeds ~80k committed rows, so it is `@tag :scale` (excluded from `mix precommit`
  / plain `mix test`; run via `SCALE_TESTS=true mix test --only scale`).
  """
  use ExUnit.Case, async: false

  import Ecto.Query

  require Logger

  alias Ecto.Adapters.SQL.Sandbox
  alias Loopctl.AdminRepo
  alias Loopctl.Knowledge
  alias Loopctl.Knowledge.VectorSearch
  alias Loopctl.Memory
  alias Loopctl.Memory.Memory, as: MemorySchema
  alias Loopctl.Memory.ScaleSeed
  alias Loopctl.Memory.Scope
  alias Loopctl.Tenants.Tenant

  @moduletag :scale
  @moduletag timeout: :timer.minutes(30)

  @query "recall my distinctive facts"

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
      # ScaleSeed.teardown/1 runs UNBOXED and COMMITS, with a :timeout bounded well
      # above the measured ~150s full-corpus delete precisely so a genuine regression
      # (corpus outgrows the bound, a lock, a mid-statement raise) FAILS LOUDLY here
      # instead of silently orphaning ~80k committed rows that accumulate across runs
      # and slow every later scale seed (see ScaleSeed.teardown/1 docs). Do NOT swallow
      # the error with a bare `rescue _ -> :ok` — that defeats the fail-loudly intent.
      # Log the leak-specific diagnostic, then re-raise so ExUnit surfaces the failure.
      try do
        unboxed(fn -> ScaleSeed.teardown(tenant.id) end)
      rescue
        e ->
          Logger.error(
            "ScaleSeed.teardown failed for tenant #{tenant.id}; ~80k committed rows may " <>
              "be orphaned in the shared test DB: #{Exception.message(e)}"
          )

          reraise e, __STACKTRACE__
      end
    end)

    {:ok, tenant: tenant, seed: seed}
  end

  test "a needle subject fills its own top-k when foreign subjects dominate the ANN pool at scale (TC-28.5.3)",
       %{tenant: tenant, seed: seed} do
    # Seeded at least the prod floor, spread across many subjects.
    assert seed.total >= ScaleSeed.prod_memory_floor()

    k = 10

    # --- Pool-depth / dominance gate (the EXPLAIN-style probe the AC promised) ---
    # Replays the SUBJECT-AGNOSTIC inner over-fetch pool that `Memory.recall/2`
    # builds internally (`memory_candidate_query/4`: index-safe kNN base + live-only
    # + raw distance), WITHOUT the outer subject filter, so we can assert on what
    # the outer filter actually has to work over. Prod-sized pool (> k) under
    # SCALE_TESTS.
    target = VectorSearch.to_embedding_list(ScaleSeed.query_embedding())
    pool = VectorSearch.pool_size(k)
    assert pool > k

    pool_query =
      MemorySchema
      |> VectorSearch.index_safe_knn_base(tenant.id, target, pool)
      |> where([m], is_nil(m.superseded_by))
      |> select([m], %{subject_id: m.subject_id})
      |> VectorSearch.put_distance(target)

    pool_subjects =
      unboxed(fn -> AdminRepo.all(pool_query) end)
      |> Enum.sort_by(& &1.distance)
      |> Enum.map(& &1.subject_id)

    # The nearest k rows of the subject-agnostic pool are ALL foreign decoys — a
    # naive "top-k of the pool" would return ZERO subject-A rows. This is the
    # dominance the AC targets, and it can only hold if the inner pool is NOT
    # subject-pre-filtered (the #170/#172 HNSW-defeating btree).
    top_k_subjects = Enum.take(pool_subjects, k)
    assert length(top_k_subjects) == k
    assert Enum.all?(top_k_subjects, &String.starts_with?(&1, "scale-decoy-"))
    refute Enum.any?(top_k_subjects, &(&1 == seed.subject_a))

    # Subject A IS in the over-fetch pool with ≥ k rows, but only BEHIND the nearer
    # decoys (first appearance past the top-k) — so the outer filter can fill k
    # without under-filling. If the pool were too shallow to hold A's k behind the
    # decoys, this would fail (the true starvation the gate guards).
    assert Enum.count(pool_subjects, &(&1 == seed.subject_a)) >= k
    first_a_rank = Enum.find_index(pool_subjects, &(&1 == seed.subject_a))
    assert first_a_rank >= k

    # --- The recall itself: A fills its full k despite the dominance ---
    scope = %Scope{tenant_id: tenant.id, subject_id: seed.subject_a, project_id: nil}

    %{results: results, meta: meta} =
      unboxed(fn -> Memory.recall(scope, query: @query, limit: k) end)

    # Full page — the subject was NOT starved by the subject-agnostic ANN pool even
    # though nearer foreign rows dominated the top of it.
    assert length(results) == k
    assert meta.underfilled == false
    # Semantic path (not the degraded ILIKE fallback): scores are floats.
    assert meta.fallback == false
    assert Enum.all?(results, fn {_m, score} -> is_float(score) end)

    returned_ids = Enum.map(results, fn {m, _score} -> m.id end)
    returned_subjects = results |> Enum.map(fn {m, _} -> m.subject_id end) |> Enum.uniq()

    # Every recalled row belongs to subject A — no foreign decoy (nearer!) nor any
    # other subject leaked through the OUTER subject filter over the ANN pool
    # (cross-subject isolation at scale, under active cross-subject dominance).
    assert returned_subjects == [seed.subject_a]

    # And every recalled id is one of subject A's OWN seeded memories — the needle
    # cluster was surfaced from behind the decoys, not lost.
    a_id_set = MapSet.new(seed.subject_a_ids)
    assert Enum.all?(returned_ids, &MapSet.member?(a_id_set, &1))

    # --- The dominance is REAL, not an artifact of A being absent ---
    # The globally-nearest row is a foreign decoy: recalling as that decoy subject
    # returns its own row with a score STRICTLY higher than A's best returned score.
    # So a nearer foreign row genuinely sat in the pool ahead of A — yet A above
    # still filled its full k.
    decoy_subject = List.first(seed.decoy_subjects)
    decoy_scope = %Scope{tenant_id: tenant.id, subject_id: decoy_subject, project_id: nil}

    %{results: decoy_results} =
      unboxed(fn -> Memory.recall(decoy_scope, query: @query, limit: k) end)

    assert decoy_results != []
    [{_m, decoy_top_score} | _] = decoy_results
    a_top_score = results |> Enum.map(fn {_m, score} -> score end) |> Enum.max()
    assert decoy_top_score > a_top_score

    # A different HAYSTACK subject in the SAME tenant, querying the SAME
    # neighbourhood, gets none of A's rows — its far rows are not even in the pool,
    # so subject A's cluster is invisible cross-subject even at scale.
    other_scope = %Scope{tenant_id: tenant.id, subject_id: "scale-subject-0", project_id: nil}

    %{results: other_results} =
      unboxed(fn -> Memory.recall(other_scope, query: @query, limit: k) end)

    refute Enum.any?(other_results, fn {m, _} -> MapSet.member?(a_id_set, m.id) end)
  end
end
