defmodule Loopctl.RemediationMatrix do
  @moduledoc """
  US-27.13 remediation-matrix scale gate: ONE calibrated, certified census that
  aggregates the per-endpoint plan gates (US-27.6b/27.7a/27.7b/27.8/27.9a/27.9b)
  into a single pass/fail matrix with calibration PROVENANCE.

  This is the "act on the alarm" layer (BA review C1, the detect→fix seam): the
  individual gates already PROVE each endpoint is index-correct at >= prod scale,
  but no single artifact OWNS the question "is EVERY endpoint green, AND was the
  run honestly calibrated?". A green matrix is only a valid `certified?` outcome
  when (AC-27.13.4a):

    * the seed is AT OR ABOVE `ScaleSeed.prod_article_floor/0`, AND
    * the effective `hnsw.ef_search` is READABLE (non-nil) on the heavy-read connection —
      a calibration-provenance signal, not a parity-with-prod claim (parity is owned by the
      under-fill gate's `assert_ef_search_parity!`), AND
    * the work-list (asserted endpoints whose plan assertion RAISED) is empty.

  An UNCALIBRATED matrix (sub-floor seed, or no readable ef_search) is rejected as
  INVALID — `certified?/1` returns `false` — rather than being allowed to
  rubber-stamp a green-but-mis-calibrated CI run. `certified?/1` is the SHARED
  function the gate test drives in BOTH directions (a real calibrated build →
  true; an injected sub-floor/nil-ef calibration map → false), mirroring how
  `scale_calibration_mismatch_scale_test.exs` drives the shared parity assertion.

  ## Coverage honesty

  Every endpoint that this census can re-verify in-process against the
  `ScaleSeed.seed/2` corpus runs its REAL request-path query builder (NOT a
  re-built stunt double — AC-27.2.4) through `Loopctl.PlanAssertions`. Two
  endpoints are `:delegated` — they are covered by a DEDICATED `:scale_nightly`
  gate but cannot be honestly re-run here:

    * `change_feed` reads the RANGE-partitioned `audit_log`, which `ScaleSeed.seed/2`
      does NOT populate (it needs `seed_changes/2` + multi-partition straddling);
      re-running its assertion here would need bespoke audit seeding. Owned by
      `by_source_change_feed_plan_scale_test.exs`.
    * `streaming_export` is an HTTP MEMORY-bound dimension (constant-memory chunked
      streaming), not a plan assertion. Owned by `streaming_export_scale_test.exs`.

  `:delegated` endpoints DO appear in the census (so coverage is complete and
  visible) but do NOT count toward `work_list` and do NOT block `certified?` —
  they have their own CI gate. They are NEVER reported as `:pass`, because the
  census did not run them; `:delegated` is an honest third result value.

  This is TEST SUPPORT (it calls `Loopctl.PlanAssertions`, itself test-support),
  not a test. The gate that drives it is
  `test/loopctl/knowledge/remediation_matrix_scale_test.exs`.

  Run everything inside `Sandbox.unboxed_run(AdminRepo, ...)` (HeavyRead routes to
  AdminRepo in test) against the committed, ANALYZEd corpus.
  """

  alias Loopctl.AdminRepo
  alias Loopctl.Knowledge
  alias Loopctl.Knowledge.Article
  alias Loopctl.Knowledge.ScaleSeed
  alias Loopctl.Knowledge.VectorSearch
  alias Loopctl.PlanAssertions

  import Ecto.Query

  @typedoc "A single endpoint census row."
  @type endpoint :: %{
          name: String.t(),
          dimension: :vector | :enumeration,
          coverage: :asserted | {:delegated, String.t()},
          result: :pass | :delegated | :uncalibrated | {:fail, String.t()}
        }

  @typedoc "The calibration provenance of the run."
  @type calibration :: %{
          seed_count: non_neg_integer(),
          prod_floor: pos_integer(),
          effective_ef_search: String.t() | nil,
          calibrated?: boolean()
        }

  @typedoc "The full remediation matrix."
  @type matrix :: %{
          calibration: calibration(),
          endpoints: [endpoint()],
          work_list: [String.t()],
          certified?: boolean()
        }

  # The tag ScaleSeed stamps on ~2% of rows (one of 50) — used as the novelty
  # prior_tag and the by-tag keyset residual so the `tags &&` GIN is selective at
  # prod scale. SAME value `distant_pairs_novelty_scale_test.exs` (`@prior_tag`)
  # and the keyset tests ("scale-tag-7") use.
  @prior_tag "scale-tag-3"
  @keyset_tag "scale-tag-7"

  # The sampled-candidate LIMIT that bounds the distant_pairs self-join (SAME source as
  # distant_pairs_novelty_scale_test.exs `@max_pair_candidates`). The genuine bound is this
  # `Limit ≤ cap` on the candidate subquery — `refute_seq_scan` alone does NOT prove the
  # O(n²) self-join is sample-bounded (the scan node's pre-LIMIT estimate ≈ corpus).
  @max_pair_candidates Application.compile_env(:loopctl, :max_pair_candidates, 1_000)

  # The canonical, COMPLETE set of endpoint names this census must cover. The gate
  # asserts the built matrix's endpoint names equal this set, so a silently-dropped
  # endpoint FAILS the test (it cannot quietly vanish from coverage). Each entry is
  # `{name, dimension, coverage}` — the SINGLE source of truth shared by the calibrated
  # census (which runs the assertions) and the uncalibrated census (which marks the
  # asserted ones `:uncalibrated`), so the two paths can never drift in coverage.
  @endpoint_specs [
    {"suggested_links", :vector, :asserted},
    {"search_semantic_results", :vector, :asserted},
    {"search_semantic_count", :vector, :asserted},
    {"auto_link_worker", :vector, :asserted},
    {"distant_pairs", :vector, :asserted},
    {"novelty", :vector, :asserted},
    {"keyset_enumeration", :enumeration, :asserted},
    {"by_source_keyset", :enumeration, :asserted},
    {"by_tag_keyset", :enumeration, :asserted},
    {"change_feed", :enumeration, {:delegated, "by_source_change_feed_plan_scale_test.exs"}},
    {"streaming_export", :enumeration, {:delegated, "streaming_export_scale_test.exs"}}
  ]

  @canonical_endpoints Enum.map(@endpoint_specs, fn {name, _dim, _cov} -> name end)

  @doc """
  The canonical, complete set of endpoint names the census must cover (the gate
  asserts the built matrix matches this exactly, so coverage can't silently rot).
  """
  @spec canonical_endpoint_names() :: [String.t()]
  def canonical_endpoint_names, do: @canonical_endpoints

  @doc """
  Builds the full remediation matrix for `tenant_id` against the committed,
  ANALYZEd `ScaleSeed.seed/2` corpus.

  Reads calibration provenance, runs ONE representative plan assertion per asserted
  endpoint (capturing `:pass` / `{:fail, reason}`), records the two `:delegated`
  endpoints, computes the `work_list` (failed asserted endpoints), and derives
  `certified?` via `certified?/1`.

  MUST be called inside `Sandbox.unboxed_run(AdminRepo, fn -> ... end)`.
  """
  @spec build(binary()) :: matrix()
  def build(tenant_id) when is_binary(tenant_id) do
    calibration = calibration(tenant_id)

    # The per-endpoint census ASSUMES a >= prod-floor corpus — every plan assertion is
    # theatre at sub-floor scale (the planner Seq-Scans happily, so it would false-GREEN
    # OR crash on a too-small corpus, e.g. no row at offset 100 for `a_target`). So an
    # UNCALIBRATED run does NOT run the census: it records each endpoint as `:uncalibrated`
    # (a not-run marker, NEVER `:pass`) and stays un-certified. This is the AC-27.13.4a
    # INVALID outcome — honest coverage with no rubber-stamp — and keeps `build/1` safe to
    # call on a sub-floor tenant (the isolation test).
    endpoints =
      if calibration.calibrated? do
        census(tenant_id)
      else
        uncalibrated_census()
      end

    work_list =
      endpoints
      |> Enum.filter(fn ep -> match?({:fail, _}, ep.result) end)
      |> Enum.map(& &1.name)

    matrix = %{
      calibration: calibration,
      endpoints: endpoints,
      work_list: work_list,
      certified?: false
    }

    %{matrix | certified?: certified?(matrix)}
  end

  @doc """
  A matrix is CERTIFIED iff it was honestly calibrated AND its work-list is empty.

  This is the anti-rubber-stamp gate (AC-27.13.4a): an UNCALIBRATED matrix (sub-floor
  seed or no readable ef_search) is rejected as INVALID — returns `false` — even when
  the work-list is empty, so a mis-calibrated green CI run cannot certify. The gate
  test drives THIS function in both directions (real calibrated build → true; injected
  sub-floor/nil-ef calibration → false), so the INVALID rejection is the actual code
  path, not a re-implemented copy.
  """
  @spec certified?(matrix()) :: boolean()
  def certified?(%{calibration: %{calibrated?: calibrated?}, work_list: work_list}) do
    calibrated? and work_list == []
  end

  @doc """
  Renders the matrix as pretty-printed JSON (stdlib `JSON`, Elixir 1.18) for CI to
  record (AC-27.13.1 — the matrix IS the recorded remediation work-list).

  Tuple results (`{:fail, reason}`, `{:delegated, file}`) are normalized to JSON-
  encodable shapes so the rendered census is a faithful, machine-readable artifact.
  """
  @spec to_json(matrix()) :: String.t()
  def to_json(matrix) do
    matrix
    |> jsonable()
    |> JSON.encode!()
    |> pretty()
  end

  # --- calibration provenance ---

  @spec calibration(binary()) :: calibration()
  defp calibration(tenant_id) do
    prod_floor = ScaleSeed.prod_article_floor()
    seed_count = tenant_article_count(tenant_id)
    effective_ef_search = effective_ef_search()

    %{
      seed_count: seed_count,
      prod_floor: prod_floor,
      effective_ef_search: effective_ef_search,
      calibrated?: seed_count >= prod_floor and is_binary(effective_ef_search)
    }
  end

  # Committed count of THIS tenant's articles (an actual count(*), like
  # PlanAssertions.assert_scale_floor!/1 — not the autovacuum estimate). Tenant-scoped
  # because each scale test seeds its OWN ~80k tenant.
  defp tenant_article_count(tenant_id) do
    %{rows: [[n]]} =
      AdminRepo.query!("SELECT count(*) FROM articles WHERE tenant_id = $1", [
        Ecto.UUID.dump!(tenant_id)
      ])

    n || 0
  end

  # The effective `hnsw.ef_search` GUC on the gate connection. Touch a vector op first
  # (pgvector lazily registers the GUC on first vector use in a session), THEN `SHOW`.
  defp effective_ef_search do
    AdminRepo.query!("SELECT '[1,2,3]'::vector")
    %{rows: [[v]]} = AdminRepo.query!("SHOW hnsw.ef_search")
    v
  end

  # --- per-endpoint census ---

  @spec census(binary()) :: [endpoint()]
  defp census(tenant_id) do
    target = a_target(tenant_id)
    qemb = VectorSearch.to_embedding_list(target.embedding)
    max_comparisons = Application.get_env(:loopctl, :article_link_max_comparisons, 50)
    prod_floor = ScaleSeed.prod_article_floor()
    cursor = deep_published_cursor(tenant_id)
    source_id = ScaleSeed.source_id_for(tenant_id, 7)

    [
      # ---- vector endpoints (asserted) ----
      asserted("suggested_links", :vector, fn ->
        query =
          Knowledge.suggestion_candidates_query(
            tenant_id,
            target.id,
            target.embedding,
            0.5,
            5,
            nil
          )

        PlanAssertions.refute_full_scan(query)
        PlanAssertions.assert_hnsw_index(query)
      end),
      asserted("search_semantic_results", :vector, fn ->
        # No-filter baseline AND the selective category+tags regression case — pre-27.7a a
        # selective filter flipped the index-ordered scan to BitmapAnd+Sort, abandoning HNSW.
        # Same scenarios the owning topk gate covers, so the census row means the same thing
        # (BA review LOW-2). The inner ANN must STILL be a single HNSW Index Scan under both.
        for opts <- [[], [category: :decision, tags: [@prior_tag]]] do
          query = Knowledge.semantic_results_query(tenant_id, qemb, opts)
          PlanAssertions.refute_full_scan(query)
          PlanAssertions.assert_hnsw_index(query)
        end
      end),
      asserted("search_semantic_count", :vector, fn ->
        query = Knowledge.semantic_count_query(tenant_id, qemb, :published, [])
        PlanAssertions.refute_sort(query)
      end),
      asserted("auto_link_worker", :vector, fn ->
        query =
          VectorSearch.candidate_query(tenant_id, target.embedding, max_comparisons,
            exclude_id: target.id,
            project_or_global: nil,
            threshold: 0.0,
            pool: VectorSearch.pool_size(max_comparisons)
          )

        PlanAssertions.refute_full_scan(query)
        PlanAssertions.assert_hnsw_index(query)
      end),
      asserted("distant_pairs", :vector, fn ->
        captured =
          PlanAssertions.capture_repo_queries(fn ->
            {:ok, _} = Knowledge.distant_pairs(tenant_id)
          end)

        between =
          Enum.filter(captured, fn {sql, _} -> sql =~ ~r/BETWEEN/i end)

        # BOTH emitted band queries (count + paginated pairs) must be present and bounded —
        # matching the owning gate exactly so the census row's `:pass` means the same thing.
        if length(between) != 2 do
          raise ExUnit.AssertionError,
            message:
              "distant_pairs expected 2 BETWEEN (band) queries (count + pairs), got #{length(between)}"
        end

        for {sql, params} <- between do
          # No unbounded corpus read AND the genuine sample bound: the candidate subquery is
          # dominated by a `Limit ≤ max_pair_candidates` (refute_seq_scan alone wouldn't prove
          # the O(n²) self-join stays sampled — architect review F2 / BA LOW-1).
          PlanAssertions.refute_seq_scan({sql, params})
          PlanAssertions.assert_article_scans_capped_by_limit({sql, params}, @max_pair_candidates)
        end
      end),
      asserted("novelty", :vector, fn ->
        query =
          Knowledge.novelty_distance_query(tenant_id, ScaleSeed.embedding_for(0), @prior_tag, nil)

        PlanAssertions.refute_seq_scan(query)
        PlanAssertions.assert_actual_scan_rows_below(query, div(prod_floor, 8))
      end),

      # ---- enumeration endpoints (asserted) ----
      asserted("keyset_enumeration", :enumeration, fn ->
        query = Knowledge.keyset_query(tenant_id, status: :published, cursor: cursor, limit: 21)
        PlanAssertions.refute_full_scan(query)
      end),
      asserted("by_source_keyset", :enumeration, fn ->
        # The real by-source request path forces status/project internally and carries
        # the non-selective source_type alongside the SELECTIVE source_id.
        query =
          Knowledge.index_keyset_query(tenant_id,
            source_type: ScaleSeed.scale_source_type(),
            source_id: source_id,
            cursor: nil,
            limit: 21
          )

        PlanAssertions.refute_full_scan(query)
      end),
      asserted("by_tag_keyset", :enumeration, fn ->
        query =
          Knowledge.index_keyset_query(tenant_id, tags: [@keyset_tag], cursor: cursor, limit: 21)

        # The tags `&&` residual on a deep keyset page has TWO legitimate bounded plans the
        # cost-based planner picks between AT the 80k floor (a cost margin a small stats
        # shift flips — see keyset_plan_scale_test.exs):
        #   * the tags GIN (`articles_tags_index`) BitmapAnd'd with the keyset btree, OR
        #   * the keyset btree (`articles_tenant_inserted_id_idx`) walked from the deep
        #     cursor with `tags &&` applied as a cheap heap Filter on the already-tiny tail.
        # Pinning EITHER index would false-RED the other (the matrix runs on every fresh
        # seed, so it WILL hit both branches). The honest, planner-agnostic invariant is the
        # one that actually matters: no unbounded Seq Scan over the corpus, AND every
        # `articles` scan stays BOUNDED (well below corpus/8) — which both bounded plans
        # satisfy and a heap-filter-over-corpus regression trips.
        PlanAssertions.refute_seq_scan(query)
        PlanAssertions.assert_scan_rows_below(query, div(prod_floor, 8))
      end),

      # ---- delegated endpoints (covered by dedicated gates, not re-run here) ----
      delegated(
        "change_feed",
        :enumeration,
        "by_source_change_feed_plan_scale_test.exs"
      ),
      delegated(
        "streaming_export",
        :enumeration,
        "streaming_export_scale_test.exs"
      )
    ]
  end

  # The census for an UNCALIBRATED run: the COMPLETE canonical set (so coverage stays
  # visible) with every ASSERTED endpoint marked `:uncalibrated` (a not-run marker, never
  # `:pass`) and the delegated ones still `:delegated`. No plan assertion is run (it would
  # be theatre at sub-floor scale) and the work-list is empty by construction — but the
  # matrix stays un-certified because `calibrated? == false` (the AC-27.13.4a INVALID
  # outcome). Shares `@endpoint_specs` with `census/1`, so the two paths can't drift.
  @spec uncalibrated_census() :: [endpoint()]
  defp uncalibrated_census do
    Enum.map(@endpoint_specs, fn
      {name, dimension, {:delegated, _} = coverage} ->
        %{name: name, dimension: dimension, coverage: coverage, result: :delegated}

      {name, dimension, :asserted} ->
        %{name: name, dimension: dimension, coverage: :asserted, result: :uncalibrated}
    end)
  end

  # Run an endpoint's representative plan assertion(s). `:pass` if the closure
  # returns normally (assertions returned :ok); `{:fail, message}` if it raised an
  # `ExUnit.AssertionError` (the plan assertion tripped). Other exceptions are NOT
  # swallowed — they signal a broken census, not a RED endpoint.
  @spec asserted(String.t(), :vector | :enumeration, (-> any())) :: endpoint()
  defp asserted(name, dimension, fun) do
    result =
      try do
        fun.()
        :pass
      rescue
        e in ExUnit.AssertionError -> {:fail, Exception.message(e)}
      end

    %{name: name, dimension: dimension, coverage: :asserted, result: result}
  end

  @spec delegated(String.t(), :vector | :enumeration, String.t()) :: endpoint()
  defp delegated(name, dimension, gate_file) do
    %{
      name: name,
      dimension: dimension,
      coverage: {:delegated, gate_file},
      result: :delegated
    }
  end

  # The representative target article: an embedded row at offset 100 in
  # (inserted_at, id) order — the SAME pick the gate tests' `a_target/1` uses.
  defp a_target(tenant_id) do
    AdminRepo.one(
      from(a in Article,
        where: a.tenant_id == ^tenant_id and not is_nil(a.embedding),
        order_by: [asc: a.inserted_at, asc: a.id],
        offset: 100,
        limit: 1,
        select: %{id: a.id, embedding: a.embedding}
      )
    )
  end

  # A genuinely-deep keyset cursor: the published row ~90% through (inserted_at, id)
  # order, so the seek is a late page (the #148 deep-page scenario), mirroring how
  # keyset_plan_scale_test.exs builds its cursor.
  defp deep_published_cursor(tenant_id) do
    published_count =
      AdminRepo.one(
        from(a in Article,
          where: a.tenant_id == ^tenant_id and a.status == :published,
          select: count(a.id)
        )
      )

    deep_offset = trunc((published_count || 0) * 0.9)

    deep =
      AdminRepo.one(
        from(a in Article,
          where: a.tenant_id == ^tenant_id and a.status == :published,
          order_by: [asc: a.inserted_at, asc: a.id],
          offset: ^deep_offset,
          limit: 1,
          select: %{id: a.id, inserted_at: a.inserted_at}
        )
      )

    {deep.inserted_at, deep.id}
  end

  # --- JSON rendering ---

  # Normalize the matrix into a JSON-encodable map (tuples → maps, atoms → strings).
  defp jsonable(matrix) do
    %{
      "calibration" => %{
        "seed_count" => matrix.calibration.seed_count,
        "prod_floor" => matrix.calibration.prod_floor,
        "effective_ef_search" => matrix.calibration.effective_ef_search,
        "calibrated" => matrix.calibration.calibrated?
      },
      "endpoints" => Enum.map(matrix.endpoints, &jsonable_endpoint/1),
      "work_list" => matrix.work_list,
      "certified" => matrix.certified?
    }
  end

  defp jsonable_endpoint(ep) do
    %{
      "name" => ep.name,
      "dimension" => Atom.to_string(ep.dimension),
      "coverage" => jsonable_coverage(ep.coverage),
      "result" => jsonable_result(ep.result)
    }
  end

  defp jsonable_coverage(:asserted), do: %{"kind" => "asserted"}

  defp jsonable_coverage({:delegated, file}),
    do: %{"kind" => "delegated", "gate" => file}

  defp jsonable_result(:pass), do: %{"status" => "pass"}
  defp jsonable_result(:delegated), do: %{"status" => "delegated"}
  defp jsonable_result(:uncalibrated), do: %{"status" => "uncalibrated"}
  defp jsonable_result({:fail, reason}), do: %{"status" => "fail", "reason" => reason}

  # stdlib JSON has no pretty-printer; round-trip through decode + a tiny indenter so
  # the recorded artifact is human-readable in CI logs without adding a dependency.
  defp pretty(json) do
    json
    |> JSON.decode!()
    |> indent(0)
  end

  defp indent(map, depth) when is_map(map) and map_size(map) > 0 do
    pad = String.duplicate("  ", depth + 1)
    close = String.duplicate("  ", depth)

    body =
      map
      |> Enum.sort_by(fn {k, _} -> k end)
      |> Enum.map_join(",\n", fn {k, v} ->
        "#{pad}#{JSON.encode!(k)}: #{indent(v, depth + 1)}"
      end)

    "{\n#{body}\n#{close}}"
  end

  defp indent(map, _depth) when is_map(map), do: "{}"

  defp indent([], _depth), do: "[]"

  defp indent(list, depth) when is_list(list) do
    pad = String.duplicate("  ", depth + 1)
    close = String.duplicate("  ", depth)
    body = Enum.map_join(list, ",\n", fn v -> "#{pad}#{indent(v, depth + 1)}" end)
    "[\n#{body}\n#{close}]"
  end

  defp indent(scalar, _depth), do: JSON.encode!(scalar)
end
