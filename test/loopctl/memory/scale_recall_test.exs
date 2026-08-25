defmodule Loopctl.Memory.ScaleRecallTest do
  @moduledoc """
  US-28.5 terminal scale gate (TC-28.5.3 / AC-28.5.5).

  Seeds a large multi-subject memory corpus (≥ the prod floor) via
  `Loopctl.Memory.ScaleSeed`, shaped to reproduce the ONE failure AC-28.5.5
  guards: a subject whose relevant memories are NOT the globally-nearest rows —
  OTHER subjects' rows are nearer and DOMINATE the inner ANN pool — must still
  fill its own top-k. This is the cross-subject-dominance scenario the retired
  placeholder named ("a subject reliably recalls its own top-k WHEN OTHER
  SUBJECTS DOMINATE THE CORPUS"), plus the pool-depth / filter-faithfulness gate
  it promised.

  The corpus has three bands (see `Loopctl.Memory.ScaleSeed`): `decoy_count`
  FOREIGN "decoy" rows that are the GLOBAL nearest to the query (`decoy_count > k`,
  so a naive top-k of the subject-agnostic pool is 100% foreign), subject A's
  needle cluster ranked BEHIND the decoys but inside the over-fetch pool, and a
  far ~80k haystack. To recall A's memories the recall must:

    * over-fetch a `(tenant_id, embedding IS NOT NULL, superseded_by IS NULL)`
      pool WITHOUT the subject filter (a selective `(tenant_id, subject_id)`
      btree there would defeat the pgvector HNSW index — #170/#172), then
    * apply the SUBJECT scope on the OUTER query, DISCARDING the nearer foreign
      decoys, and return every one of A's rows the pool held (up to k).

  The gate can genuinely FAIL on the risk it guards: if the inner pool were
  subject-pre-filtered the pool probe would show A un-dominated (no foreign row
  nearer than A); if the outer filter STARVED A it would drop A rows the pool
  held; if the outer filter LEAKED, another subject's rows would appear in A's
  result. The gate asserts the outer filter is FAITHFUL to the pool the ANN
  surfaced, and a decoy-subject recall proves the nearer foreign rows are real —
  not an artifact of A being absent.

  ## Note on ef_search parity + why the assertions are POOL-RELATIVE

  This gate is `@tag :scale`, so it ONLY runs via `SCALE_TESTS=true mix test
  --only scale` (test_helper.exs includes `:scale` only when `SCALE_TESTS` is
  set). Under `SCALE_TESTS`, `config/test.exs` SKIPS the tiny-pool shrink
  (`:max_vector_pool = 6`) and leaves the PROD defaults (factor 5 / floor 100 /
  cap 500), so `pool_size(k = 5) = 25 |> max(100) |> min(500) |> max(5) = 100`.
  The regime is therefore `pool = 100 > k = 5` — a genuine over-fetch, so the
  outer subject filter is doing real work (discarding nearer foreign rows).

  ## Why k = 5 and decoy_count = 8 (the HNSW reachability ceiling)

  At prod's effective `hnsw.ef_search` (default 40) over the ~80k corpus, the
  approximate HNSW traversal reliably surfaces only roughly the nearest ~20 rows
  of the near band into the over-fetch pool (measured with a direct pool probe at
  80k across independent HNSW builds; deeper near-band rows need ef_search ≥ ~200).
  So `decoy_count + k` MUST stay comfortably under that ~20-row ceiling for subject
  A to fill a FULL top-k behind the dominating decoys. `Loopctl.Memory.ScaleSeed`
  seeds `decoy_count = 8`; the gate uses `k = 5` (sum 13, with ~12 of A's rows
  reaching the pool) — healthy margin. The pre-fix `decoy_count = 20` + `k = 10`
  (sum 30) was structurally unreachable at ef_search 40: subject A surfaced ZERO
  pool rows, which is why AC-28.5.5 failed on execution. See the ScaleSeed
  reachability-ceiling note before changing either constant.

  CRUCIALLY, the gate runs at prod's EFFECTIVE `hnsw.ef_search` (pgvector default
  40) and MUST NOT raise it: the repo forbids a scale gate from diverging from
  prod ef_search, because a higher one recalls MORE and turns the gate
  false-GREEN (`PlanAssertions.assert_ef_search_parity!`,
  `Loopctl.Knowledge.ScaleCalibrationMismatchScaleTest`). At 80k with ef_search
  40 the inner ANN is an APPROXIMATION of the true nearest-`pool`: WHICH near rows
  it surfaces varies per HNSW build (randomized layer assignment), so an EXACT
  "the top-k are all decoys" / "A always fills exactly k" assertion is inherently
  FLAKY (a buried decoy node — or several — can be missed at ef_search 40). This
  gate therefore asserts the invariant that holds REGARDLESS of the ANN's
  approximation: the OUTER subject filter is FAITHFUL to whatever the pool
  surfaced — it returns EXACTLY subject A's rows that made it into the pool
  (nearest-first, capped at k), never a nearer foreign decoy, and it SIGNALS
  under-fill (`meta.underfilled`) exactly when the pool held < k of A's rows. That
  is exactly what AC-28.5.5 requires — "the subject filter did not get starved by
  HNSW under-fill" is a statement about the FILTER (it adds no starvation of its
  own beyond the ANN's), not about the ANN's absolute recall. Expectations are
  pinned to a direct probe of the SAME subject-agnostic pool the recall draws from
  (byte-identical inner query, same persisted HNSW graph, same ef_search), so the
  comparison is exact, not approximate.

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

    # `config/test.exs` points EVERY injected collaborator at a Mox mock for the whole
    # test env, and this module does not `use Loopctl.DataCase`, so nothing has stubbed
    # them. `Memory.recall/2` alone reaches `Embeddings.side_table_reads_enabled?/0`, but
    # hand-picking one mock at a time is what kept the nightly red — the next unstubbed
    # mock just repeats it. `stub_all_defaults/0` is the single source of truth, so a mock
    # added to DataCase is covered here automatically. Registered in THIS process, which is
    # the `set_mox_global/0` owner above (global mode lets only the owner register stubs).
    Loopctl.DataCase.stub_all_defaults()

    # The module-specific embedding stub MUST come after `stub_all_defaults/0`, which
    # installs a generic per-tenant `generate_embedding` default — the LAST `stub` for a
    # given mock/arity wins. This gate is ANN-sensitive: it asserts where subject A's rows
    # land in an HNSW pool relative to seeded decoys, so it needs the exact ScaleSeed query
    # vector, not a generic one.
    #
    # BOTH arities are pinned. `/3` carries the explicit `:model` override (US-41.1
    # AC-41.1.10) and `stub_all_defaults/0` defaults it to the generic vector too, so
    # leaving it unpinned would silently hand a wrong query vector to any caller that takes
    # the model-override path.
    Mox.stub(Loopctl.MockEmbeddingClient, :generate_embedding, fn _tenant_id, _text ->
      {:ok, ScaleSeed.query_embedding()}
    end)

    Mox.stub(Loopctl.MockEmbeddingClient, :generate_embedding, fn _tenant_id, _text, _opts ->
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

  # The TRUE nearest distance among the decoys and among subject A's rows.
  #
  # Two separate filtered aggregates rather than one GROUP BY. The grouped spelling is the
  # obvious one and it does not work: Ecto renders a pinned `^subject_a` as a fresh
  # parameter per occurrence, so `select: fragment("? = ?", m.subject_id, ^subject_a)` with
  # the same fragment in `group_by` emits `$1` in the SELECT and `$5` in the GROUP BY, and
  # Postgres — which compares grouping expressions syntactically — rejects it with
  # `42803 grouping_error`. Two queries carry no such trap.
  #
  # `MIN()` is load-bearing, not incidental: an aggregate cannot be served by an HNSW
  # ordering, so Postgres must compute every distance in the filtered set and the answer is
  # EXACT. `ORDER BY distance LIMIT 1` would read more naturally and would be wrong here —
  # the planner could serve it from the very approximate index this assertion exists to be
  # independent of.
  defp exact_nearest_by_class(tenant_id, target, subject_a) do
    {nearest(tenant_id, target, dynamic([m], like(m.subject_id, "scale-decoy-%"))) ||
       flunk("no decoy rows in the seeded corpus — the seed did not run"),
     nearest(tenant_id, target, dynamic([m], m.subject_id == ^subject_a)) ||
       flunk("no subject-A rows in the seeded corpus — the seed did not run")}
  end

  defp nearest(tenant_id, target, subject_filter) do
    unboxed(fn ->
      AdminRepo.one(
        from(m in MemorySchema,
          where: m.tenant_id == ^tenant_id,
          where: is_nil(m.superseded_by),
          where: ^subject_filter,
          select: min(fragment("? <=> ?::vector", m.embedding, ^target))
        )
      )
    end)
  end

  test "a needle subject fills its own top-k when foreign subjects dominate the ANN pool at scale (TC-28.5.3)",
       %{tenant: tenant, seed: seed} do
    # Seeded at least the prod floor, spread across many subjects.
    assert seed.total >= ScaleSeed.prod_memory_floor()

    # k = 5 with decoy_count = 8: both fit under the ~20-row HNSW reachability
    # ceiling at prod ef_search 40 (see the moduledoc), so the 8 decoys dominate
    # the top-k AND subject A still fills a FULL k behind them. Do not raise k
    # without re-measuring that ceiling at 80k.
    k = 5

    # --- Pool-depth / dominance gate (the EXPLAIN-style probe the AC promised) ---
    # Replays the SUBJECT-AGNOSTIC inner over-fetch pool that `Memory.recall/2`
    # builds internally (`memory_candidate_query/4`: index-safe kNN base + live-only
    # + raw distance), WITHOUT the outer subject filter, so we can assert on what the
    # outer filter actually has to work over. Prod-sized pool (> k) under SCALE_TESTS.
    #
    # The assertions here are POOL-RELATIVE by design. This gate runs at prod's
    # EFFECTIVE `hnsw.ef_search` (default 40) — the repo forbids a scale gate from
    # diverging from prod ef_search, since a higher one would make recall false-GREEN
    # (`PlanAssertions.assert_ef_search_parity!`,
    # `Loopctl.Knowledge.ScaleCalibrationMismatchScaleTest`). At 80k with ef_search 40
    # the inner ANN is an APPROXIMATION of the true nearest-`pool`, and WHICH near rows
    # it surfaces varies per HNSW build (randomized layer assignment) — an EXACT
    # "top-k are all decoys" assertion is therefore flaky (a single buried decoy node,
    # or several, can be missed). So we assert the invariant that holds regardless of
    # the approximation: the OUTER subject filter is FAITHFUL to whatever the pool
    # surfaced — it returns EXACTLY subject A's rows that made it into the pool
    # (nearest-first, capped at k), never a foreign row, and SIGNALS under-fill when the
    # pool held < k of A's rows. That is precisely AC-28.5.5: "the subject filter did
    # not get starved by HNSW under-fill" — the filter adds NO starvation of its own
    # beyond the ANN's, which is the #170/#172 property (US-28.2 AC-28.2.3).
    target = VectorSearch.to_embedding_list(ScaleSeed.query_embedding())
    pool = VectorSearch.pool_size(k)
    assert pool > k

    pool_query =
      MemorySchema
      |> VectorSearch.index_safe_knn_base(tenant.id, target, pool)
      |> where([m], is_nil(m.superseded_by))
      |> select([m], %{id: m.id, subject_id: m.subject_id})
      |> VectorSearch.put_distance(target)

    # The pool the RECALL filters over. Its inner query is byte-identical to
    # `memory_candidate_query/4`'s inner (same `index_safe_knn_base` + live-only filter
    # + `pool_size`), and the HNSW graph is persisted in the index (not per-connection)
    # and read at the same default ef_search — so this probe and the recall draw the
    # SAME rows in the SAME distance order. That identity is what lets the pool-relative
    # expectations below be EXACT rather than approximate.
    pool_rows =
      unboxed(fn -> AdminRepo.all(pool_query) end)
      |> Enum.sort_by(& &1.distance)

    pool_subjects = Enum.map(pool_rows, & &1.subject_id)

    first_a_rank = Enum.find_index(pool_subjects, &(&1 == seed.subject_a))
    assert first_a_rank != nil, "subject A must appear in the subject-agnostic ANN pool"

    # Cross-subject DOMINANCE, asserted against TRUE distances rather than against what
    # this HNSW build happened to surface.
    #
    # This assertion used to be `first_a_rank >= 1` — "the pool ranks at least one foreign
    # decoy ahead of A". That is a claim about the APPROXIMATION, and the comment three
    # lines above already conceded the approximation is not stable: which near rows the
    # index surfaces "varies per HNSW build (randomized layer assignment)". It duly failed
    # on a freshly built index (minis, 2026-08-25, `first_a_rank == 0`) with nothing wrong
    # in the product — no decoy had been surfaced, so A was the pool's nearest row. An
    # assertion belongs on something that cannot legitimately happen; this one could, and
    # then did.
    #
    # The dominance the test actually needs is a property of the SEED, and there it IS an
    # invariant: `ScaleSeed`'s moduledoc states that every decoy sits at a phase in
    # `0..(decoy_count - 1)` while A starts at `subject_a_phase_lo = decoy_count`, so
    # "EVERY decoy is strictly NEARER to the query than any of subject A's rows". Asserting
    # THAT is deterministic, and it is strictly stronger than the old form: the old one was
    # satisfied by a single decoy surfacing, this one holds over all of them.
    #
    # What is deliberately NOT asserted any more is that the outer filter had foreign rows
    # to discard on this particular run. Whether the ANN surfaces a decoy is the index's
    # choice, not the product's, and every claim about the FILTER below is pool-relative —
    # they hold, and stay exact, whatever the pool turned out to contain.
    {decoy_nearest, a_nearest} = exact_nearest_by_class(tenant.id, target, seed.subject_a)

    assert decoy_nearest < a_nearest,
           "seed invariant broken: the nearest decoy (#{decoy_nearest}) must be strictly " <>
             "nearer to the query than the nearest subject-A row (#{a_nearest}) — see " <>
             "ScaleSeed's phase layout (decoys at phases 0..decoy_count-1, A from " <>
             "subject_a_phase_lo = decoy_count)"

    # Every row the pool ranks AHEAD of A is a foreign decoy — never A, never haystack.
    # Exact even under approximation: distances are computed in SQL, and by seed
    # construction ONLY the 8 decoys have a true cosine distance smaller than any A row
    # (the haystack is strictly farther than A), so any row nearer than A can ONLY be a
    # decoy.
    nearer_than_a = Enum.take(pool_subjects, first_a_rank)

    assert Enum.all?(nearer_than_a, &String.starts_with?(&1, "scale-decoy-")),
           "rows nearer than A must all be foreign decoys, got: #{inspect(nearer_than_a)}"

    # Subject A's OWN rows that made it into the pool, nearest-first. The outer filter
    # can return AT MOST these (capped at k); returning EXACTLY them (dropping none) is
    # the "filter did not starve" invariant.
    a_pool_ids =
      pool_rows |> Enum.filter(&(&1.subject_id == seed.subject_a)) |> Enum.map(& &1.id)

    a_in_pool = length(a_pool_ids)

    # A FULL top-k of subject A's rows reaches the pool behind the dominating decoys —
    # this is the core AC-28.5.5 property ("the subject reliably recalls its own
    # top-k"): the outer subject filter is NOT starved by HNSW under-fill. It holds
    # only because decoy_count (8) + k (5) sit under the ~20-row reachability ceiling
    # at prod ef_search 40 (see the moduledoc); at 80k this is reliably ~12 of A's
    # rows, comfortably ≥ k across independent HNSW builds. If a future change
    # re-inflates decoy_count/k past the ceiling, THIS is the assertion that fails
    # loudly (A surfaces < k, the pre-fix regression).
    assert a_in_pool >= k,
           "subject A must surface a FULL top-k (#{k}) into the pool behind the decoys, " <>
             "got #{a_in_pool} — decoy_count + k likely exceeds the HNSW reachability ceiling"

    expected_a_ids = Enum.take(a_pool_ids, k)

    # --- The recall itself: the outer subject filter faithfully returns A's pool rows ---
    scope = %Scope{tenant_id: tenant.id, subject_id: seed.subject_a, project_id: nil}

    %{results: results, meta: meta} =
      unboxed(fn -> Memory.recall(scope, query: @query, limit: k) end)

    returned_ids = Enum.map(results, fn {m, _score} -> m.id end)
    returned_subjects = results |> Enum.map(fn {m, _} -> m.subject_id end) |> Enum.uniq()

    # The filter returned EXACTLY subject A's nearest-k pool rows, in order: it dropped
    # no A row the pool held (no filter-induced starvation) and admitted no nearer
    # foreign decoy (no cross-subject leak). This is the core AC-28.5.5 claim, made
    # deterministic by pinning the expectation to the SAME pool the recall drew from.
    # `a_in_pool >= k` above ⇒ this is a FULL page of exactly k subject-A rows.
    assert returned_ids == expected_a_ids
    assert length(results) == k
    assert returned_subjects == [seed.subject_a]

    # Semantic path (not the degraded ILIKE fallback): scores are floats.
    assert meta.fallback == false
    assert Enum.all?(results, fn {_m, score} -> is_float(score) end)

    # A FULL top-k recall is NOT under-filled: because the pool held ≥ k of A's rows
    # (asserted above, with margin at prod ef_search 40), the outer subject filter
    # returns a complete page — the direct proof that the filter added NO starvation of
    # its own beyond the ANN (US-28.2 AC-28.2.4). The flag is still tied to the pool
    # truth (`a_in_pool < k`), which is `false` here, so a seed regression that dropped
    # A below k would flip both this and the `a_in_pool >= k` guard above.
    assert meta.underfilled == a_in_pool < k
    refute meta.underfilled

    # Every recalled id is one of subject A's OWN seeded memories.
    a_id_set = MapSet.new(seed.subject_a_ids)
    assert Enum.all?(returned_ids, &MapSet.member?(a_id_set, &1))

    # --- The dominance is REAL, not an artifact of A being absent ---
    # The pool's NEAREST row is a foreign decoy (asserted above: `first_a_rank >= 1`
    # and every nearer-than-A row is a `scale-decoy-`). Recall as THAT decoy subject —
    # one the pool DEMONSTRABLY surfaced, hence recall-reachable at this ef_search — and
    # show its own row returns with a score STRICTLY higher than A's best. So a nearer
    # foreign row genuinely sat in the pool ahead of A, yet A above still recalled its
    # own rows through the outer filter.
    #
    # We pick the nearest decoy the POOL surfaced (`List.first(pool_subjects)`), NOT
    # `seed.decoy_subjects` head (the phase-0 row): that row is nearest-by-cosine but is
    # the FIRST node inserted into the HNSW graph and then buried under ~80k rows, so
    # the approximate ef_search-40 traversal can legitimately fail to reach that ONE
    # node — a graph-reachability artifact of insertion order (see `ScaleSeed`'s
    # interleave note), not a recall defect. Asserting on a decoy the pool surfaced
    # tests the recall design at prod ef_search, not HNSW's approximation of the single
    # deepest-buried node.
    nearest_decoy_subject = List.first(pool_subjects)
    assert String.starts_with?(nearest_decoy_subject, "scale-decoy-")

    decoy_scope = %Scope{tenant_id: tenant.id, subject_id: nearest_decoy_subject, project_id: nil}

    %{results: decoy_results} =
      unboxed(fn -> Memory.recall(decoy_scope, query: @query, limit: k) end)

    assert decoy_results != []
    [{_m, decoy_top_score} | _] = decoy_results
    a_top_score = results |> Enum.map(fn {_m, score} -> score end) |> Enum.max()
    assert decoy_top_score > a_top_score

    # A different HAYSTACK subject in the SAME tenant, querying the SAME neighbourhood,
    # gets none of A's rows — its far rows are not even in the pool, so subject A's
    # cluster is invisible cross-subject even at scale.
    other_scope = %Scope{tenant_id: tenant.id, subject_id: "scale-subject-0", project_id: nil}

    %{results: other_results} =
      unboxed(fn -> Memory.recall(other_scope, query: @query, limit: k) end)

    refute Enum.any?(other_results, fn {m, _} -> MapSet.member?(a_id_set, m.id) end)
  end
end
