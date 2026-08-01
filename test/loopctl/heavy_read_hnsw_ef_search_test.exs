defmodule Loopctl.HeavyReadHnswEfSearchTest do
  @moduledoc """
  US-38.4 (TC-38.4.1, query side): per-query `hnsw.ef_search` — `opts/1` attaches
  `:hnsw_ef_search` for ANN endpoints ONLY on a non-default `SystemConfig` value, the
  clamp keeps it inside pgvector's accepted `[1, 1000]`, and an ANN heavy read issues
  `SET LOCAL hnsw.ef_search` on its own transaction (never at the default, so a
  role-level `ALTER ROLE ... SET hnsw.ef_search` is honored, not shadowed).

  ## Why `async: false` (deliberate, not an oversight)

  `hnsw_ef_search/0` reads `SystemConfig.get_int("hnsw_ef_search", ...)`, which reads the
  VM-global `:persistent_term` key `{Loopctl.SystemConfig, "hnsw_ef_search"}`. The tests
  below PRIME that key to a non-default value (see `prime_ef_search/1`). That key is the
  SAME global read by every `@ann_endpoint` heavy read fleet-wide — including the REAL
  ANN reads in the `async: true` files `test/loopctl/memory/dual_index_recall_test.exs`
  and `test/loopctl/knowledge/vector_search_test.exs`. Priming it from an `async: true`
  module would let a concurrently-running cross-file ANN reader observe the primed value
  and emit a different `SET LOCAL hnsw.ef_search` in its own transaction — an
  async-global-state flake. The `[1, 1000]` clamp in `hnsw_ef_search/0` does NOT provide
  cross-test isolation: it only prevents pgvector from RAISING on an out-of-range GUC; a
  primed in-range value still bleeds into a concurrent reader's recall breadth. So these
  persistent_term-mutating tests live here, isolated: a non-async module never runs
  concurrently with any other module (`ExUnit.Case` `:async` docs), so no ANN reader is
  running while the global is primed. The purely-structural sibling assertions on the
  same wrapper stay in the `async: true` `HeavyReadTest`.
  """
  use Loopctl.DataCase, async: false

  alias Loopctl.HeavyRead
  alias Loopctl.Knowledge.Article

  import Ecto.Query

  describe "per-query hnsw.ef_search (US-38.4, TC-38.4.1 query side)" do
    test "opts/1 attaches :hnsw_ef_search for ANN endpoints ONLY on a non-default value" do
      # At the pgvector default (40) NO ef_search key is attached — so an unconditional
      # SET LOCAL never shadows a role-level `ALTER ROLE SET hnsw.ef_search` (US-38.4 review).
      assert HeavyRead.hnsw_ef_search() == 40, "precondition: default config"

      for endpoint <- HeavyRead.ann_endpoints() do
        refute Keyword.has_key?(HeavyRead.opts(endpoint), :hnsw_ef_search),
               "expected #{endpoint} opts to carry NO :hnsw_ef_search at the default"
      end

      # A non-default SystemConfig value → every ANN endpoint carries it (the fleet-wide
      # override), and every non-ANN endpoint still never does.
      prime_ef_search(100)
      assert HeavyRead.hnsw_ef_search() == 100

      for endpoint <- HeavyRead.ann_endpoints() do
        assert Keyword.get(HeavyRead.opts(endpoint), :hnsw_ef_search) == 100,
               "expected non-default #{endpoint} opts to carry :hnsw_ef_search = 100"
      end

      for endpoint <- HeavyRead.known_endpoints() -- HeavyRead.ann_endpoints() do
        refute Keyword.has_key?(HeavyRead.opts(endpoint), :hnsw_ef_search),
               "expected non-ANN #{endpoint} opts to NOT carry :hnsw_ef_search"
      end
    end

    test "ann_endpoints/0 is a subset of known_endpoints/0 (no drift)" do
      assert HeavyRead.ann_endpoints() -- HeavyRead.known_endpoints() == []
    end

    test "distant_pairs / distant_pairs_bridge are NOT ANN endpoints (column-to-column self-join, HNSW N/A)" do
      # They read articles.embedding but are `a.embedding <=> b.embedding` self-joins with no
      # $const target, so hnsw.ef_search cannot apply (mirrors CosineLintExceptions). Guards
      # against them being re-added to @ann_endpoints (a dead SET LOCAL round-trip).
      refute :distant_pairs in HeavyRead.ann_endpoints()
      refute :distant_pairs_bridge in HeavyRead.ann_endpoints()
      # ...but they remain known (still weight-classified heavy reads).
      assert :distant_pairs in HeavyRead.known_endpoints()
      assert :distant_pairs_bridge in HeavyRead.known_endpoints()
    end

    test "hnsw_ef_search/0 reads the SystemConfig default (40)" do
      assert HeavyRead.hnsw_ef_search() == 40
    end

    test "hnsw_ef_search/0 clamps an out-of-range SystemConfig value into [1, 1000]" do
      # pgvector REJECTS ef_search outside [1, 1000] (raising + rolling back the whole heavy
      # read), so the max(1) |> min(1000) clamp is load-bearing for availability. Exercise
      # both bounds AND the interior via the live-tunable SystemConfig cache.
      prime_ef_search(5_000)
      assert HeavyRead.hnsw_ef_search() == 1_000, "above-range value clamps to the max bound"

      prime_ef_search(0)
      assert HeavyRead.hnsw_ef_search() == 1, "zero clamps to the min bound"

      prime_ef_search(-5)
      assert HeavyRead.hnsw_ef_search() == 1, "a negative value clamps to the min bound"

      prime_ef_search(100)
      assert HeavyRead.hnsw_ef_search() == 100, "an in-range value passes through unclamped"
    end

    test "an ANN heavy read issues SET LOCAL hnsw.ef_search for a non-default value" do
      prime_ef_search(100)
      tenant = fixture(:tenant)
      q = from(a in Article, where: a.tenant_id == ^tenant.id, select: %{id: a.id})

      captured =
        Loopctl.PlanAssertions.capture_repo_queries(fn ->
          HeavyRead.all(tenant.id, q, HeavyRead.opts(:vector_search))
        end)

      sqls = Enum.map(captured, fn {sql, _params} -> sql end)

      assert Enum.any?(sqls, &(&1 =~ ~r/SET LOCAL hnsw\.ef_search = 100/)),
             "expected the ANN read to issue SET LOCAL hnsw.ef_search = 100, got: #{inspect(sqls)}"
    end

    test "an ANN heavy read at the default value issues NO SET LOCAL hnsw.ef_search (ALTER ROLE preserved)" do
      assert HeavyRead.hnsw_ef_search() == 40, "precondition: default config"
      tenant = fixture(:tenant)
      q = from(a in Article, where: a.tenant_id == ^tenant.id, select: %{id: a.id})

      captured =
        Loopctl.PlanAssertions.capture_repo_queries(fn ->
          HeavyRead.all(tenant.id, q, HeavyRead.opts(:vector_search))
        end)

      sqls = Enum.map(captured, fn {sql, _params} -> sql end)

      refute Enum.any?(sqls, &(&1 =~ ~r/hnsw\.ef_search/)),
             "expected an ANN read at the default to NOT set hnsw.ef_search (so a role-level " <>
               "ALTER ROLE default is honored, not shadowed), got: #{inspect(sqls)}"
    end

    test "a non-ANN heavy read does NOT issue SET LOCAL hnsw.ef_search" do
      # Even with a non-default value primed, a non-ANN endpoint never touches the GUC.
      prime_ef_search(100)
      tenant = fixture(:tenant)
      q = from(a in Article, where: a.tenant_id == ^tenant.id, select: %{id: a.id})

      captured =
        Loopctl.PlanAssertions.capture_repo_queries(fn ->
          HeavyRead.all(tenant.id, q, HeavyRead.opts(:change_feed))
        end)

      sqls = Enum.map(captured, fn {sql, _params} -> sql end)

      refute Enum.any?(sqls, &(&1 =~ ~r/hnsw\.ef_search/)),
             "expected a non-ANN read to NOT touch hnsw.ef_search, got: #{inspect(sqls)}"
    end
  end

  describe "per-query hnsw.iterative_scan (#488)" do
    test "hnsw_iterative_scan/0 maps SystemConfig int codes to modes (0/unknown => off)" do
      # Prime 0 EXPLICITLY rather than relying on the ambient default, so the mapping
      # contract is pinned independently of what the shipped default happens to be.
      prime_iterative_scan(0)
      assert HeavyRead.hnsw_iterative_scan() == "off", "explicit 0 => off"

      prime_iterative_scan(1)
      assert HeavyRead.hnsw_iterative_scan() == "relaxed_order"

      prime_iterative_scan(2)
      assert HeavyRead.hnsw_iterative_scan() == "strict_order"

      prime_iterative_scan(99)
      assert HeavyRead.hnsw_iterative_scan() == "off", "an unknown code falls back to off"
    end

    test "hnsw_max_scan_tuples/0 reads the pgvector default and clamps out-of-range" do
      assert HeavyRead.hnsw_max_scan_tuples() == 20_000, "default"

      prime_max_scan_tuples(5_000_000)
      assert HeavyRead.hnsw_max_scan_tuples() == 1_000_000, "above-range clamps to max"

      prime_max_scan_tuples(0)
      assert HeavyRead.hnsw_max_scan_tuples() == 1, "zero clamps to min"
    end

    test "opts/1 attaches :hnsw_iterative_scan for ANN endpoints ONLY when enabled" do
      # OFF: no key on any endpoint, so pgvector < 0.8 (no such GUC) is never touched.
      # Primed explicitly so the assertion does not depend on the ambient default.
      prime_iterative_scan(0)

      for endpoint <- HeavyRead.ann_endpoints() do
        refute Keyword.has_key?(HeavyRead.opts(endpoint), :hnsw_iterative_scan),
               "expected #{endpoint} opts to carry NO :hnsw_iterative_scan at OFF"
      end

      prime_iterative_scan(1)

      for endpoint <- HeavyRead.ann_endpoints() do
        assert Keyword.get(HeavyRead.opts(endpoint), :hnsw_iterative_scan) == "relaxed_order",
               "expected enabled ANN #{endpoint} opts to carry :hnsw_iterative_scan"
      end

      for endpoint <- HeavyRead.known_endpoints() -- HeavyRead.ann_endpoints() do
        refute Keyword.has_key?(HeavyRead.opts(endpoint), :hnsw_iterative_scan),
               "expected non-ANN #{endpoint} opts to NOT carry :hnsw_iterative_scan"
      end
    end

    test "an enabled ANN heavy read issues SET LOCAL hnsw.iterative_scan + hnsw.max_scan_tuples" do
      prime_iterative_scan(1)
      prime_max_scan_tuples(50_000)
      tenant = fixture(:tenant)
      q = from(a in Article, where: a.tenant_id == ^tenant.id, select: %{id: a.id})

      sqls =
        Loopctl.PlanAssertions.capture_repo_queries(fn ->
          HeavyRead.all(tenant.id, q, HeavyRead.opts(:vector_search))
        end)
        |> Enum.map(fn {sql, _params} -> sql end)

      assert Enum.any?(sqls, &(&1 =~ ~r/SET LOCAL hnsw\.iterative_scan = relaxed_order/)),
             "expected SET LOCAL hnsw.iterative_scan = relaxed_order, got: #{inspect(sqls)}"

      assert Enum.any?(sqls, &(&1 =~ ~r/SET LOCAL hnsw\.max_scan_tuples = 50000/)),
             "expected SET LOCAL hnsw.max_scan_tuples = 50000, got: #{inspect(sqls)}"
    end

    test "an ANN heavy read at OFF issues NO SET LOCAL hnsw.iterative_scan" do
      # OFF must touch NOTHING iterative-scan — this is what keeps the feature inert (and
      # safe on a pgvector < 0.8 backend without the GUC) until an operator opts in.
      # Primed explicitly so the assertion does not depend on the ambient default — which
      # matters MORE since #535, not less: `config/test.exs` now pins
      # `:hnsw_iterative_scan_default` to 1, so the ambient value is ON and this OFF-path
      # test would assert nothing without the explicit prime. `Loopctl.ConfigEmbeddingReadPathTest`
      # bars that pin from every NON-test config and asserts it stays in `config/test.exs`.
      # These assertions are the compensating coverage `config/test.exs` cites for the OFF
      # path — if this test moves, update that citation.
      prime_iterative_scan(0)
      assert HeavyRead.hnsw_iterative_scan() == "off", "precondition: OFF"
      tenant = fixture(:tenant)
      q = from(a in Article, where: a.tenant_id == ^tenant.id, select: %{id: a.id})

      sqls =
        Loopctl.PlanAssertions.capture_repo_queries(fn ->
          HeavyRead.all(tenant.id, q, HeavyRead.opts(:vector_search))
        end)
        |> Enum.map(fn {sql, _params} -> sql end)

      refute Enum.any?(sqls, &(&1 =~ ~r/iterative_scan|max_scan_tuples/)),
             "expected an ANN read at OFF to touch NO iterative-scan GUC, got: #{inspect(sqls)}"
    end

    test "a non-ANN heavy read does NOT issue SET LOCAL hnsw.iterative_scan even when enabled" do
      prime_iterative_scan(1)
      tenant = fixture(:tenant)
      q = from(a in Article, where: a.tenant_id == ^tenant.id, select: %{id: a.id})

      sqls =
        Loopctl.PlanAssertions.capture_repo_queries(fn ->
          HeavyRead.all(tenant.id, q, HeavyRead.opts(:change_feed))
        end)
        |> Enum.map(fn {sql, _params} -> sql end)

      refute Enum.any?(sqls, &(&1 =~ ~r/iterative_scan|max_scan_tuples/)),
             "expected a non-ANN read to NOT touch iterative-scan GUCs, got: #{inspect(sqls)}"
    end

    test "version_at_least?/2 parses pgvector versions and FAILS CLOSED on malformed input" do
      assert HeavyRead.version_at_least?("0.8.0", {0, 8, 0})
      assert HeavyRead.version_at_least?("0.8.5", {0, 8, 0})
      assert HeavyRead.version_at_least?("0.9.0", {0, 8, 0})
      assert HeavyRead.version_at_least?("1.0.0", {0, 8, 0})
      assert HeavyRead.version_at_least?("0.8", {0, 8, 0}), "missing patch defaults to 0"

      refute HeavyRead.version_at_least?("0.7.4", {0, 8, 0})
      refute HeavyRead.version_at_least?("0.7", {0, 8, 0})
      refute HeavyRead.version_at_least?("garbage", {0, 8, 0}), "unparseable fails closed"
      refute HeavyRead.version_at_least?("", {0, 8, 0})
      refute HeavyRead.version_at_least?("0.x.0", {0, 8, 0})
    end

    test "iterative_scan_supported?/0 detects the test DB's pgvector (>= 0.8) — the enable gate" do
      # On a < 0.8 backend this returns false, so enabling the config there is a NO-OP; the
      # deterministic decision logic is covered by version_at_least?/2 above. Here we assert
      # the live probe succeeds against the actual test DB so the emission tests' precondition
      # (that iterative scan CAN be enabled) is real, not assumed.
      clear_iterative_scan_probe_cache()

      assert HeavyRead.iterative_scan_supported?(), """
      The live pgvector capability probe did NOT report >= 0.8 against the test database.

      Either the backend's pgvector is too old (CI must run the pgvector/pgvector:pg16
      image; check `SELECT extversion FROM pg_extension WHERE extname = 'vector'`), or the
      probe was inconclusive (HeavyReadRepo checkout failure — see the warning above).

      The SET LOCAL emission tests in this describe block depend on this precondition.
      """
    end

    test "enabled + UNSUPPORTED backend emits NO iterative-scan GUC (the < 0.8 safety gate)" do
      # The composed guarantee the moduledoc promises: an operator flipping the lever on a
      # pgvector < 0.8 backend is a NO-OP, not a fleet-wide ANN outage. Primed through the
      # probe cache because the capability is a property of the connected backend.
      prime_iterative_scan(1)
      prime_iterative_scan_supported(false)

      for endpoint <- HeavyRead.ann_endpoints() do
        refute Keyword.has_key?(HeavyRead.opts(endpoint), :hnsw_iterative_scan),
               "expected #{endpoint} to carry NO :hnsw_iterative_scan on an unsupported backend"
      end
    end

    test "an EXPIRED probe verdict is re-probed rather than pinned for the VM lifetime" do
      # A stale `false` (e.g. negative-cached during a pool blip) must not silently no-op the
      # operator's lever forever, and a stale `true` must not outlive a backend change.
      prime_expired_iterative_scan_supported(false)

      assert HeavyRead.iterative_scan_supported?(),
             "expected an expired cache entry to re-probe the live backend"
    end
  end

  @probe_cache_key {Loopctl.HeavyRead, :iterative_scan_supported}

  # The probe caches a VM-global `:persistent_term` verdict. Every mutation of it — including
  # the one the LIVE probe performs — is erased on exit, exactly like the prime_* helpers
  # below, so the unsupported / re-probe branches stay reachable for later tests.
  defp clear_iterative_scan_probe_cache do
    :persistent_term.erase(@probe_cache_key)
    on_exit(fn -> :persistent_term.erase(@probe_cache_key) end)
  end

  defp prime_iterative_scan_supported(verdict) do
    :persistent_term.put(
      @probe_cache_key,
      {verdict, System.monotonic_time(:millisecond) + 60_000}
    )

    on_exit(fn -> :persistent_term.erase(@probe_cache_key) end)
  end

  defp prime_expired_iterative_scan_supported(verdict) do
    :persistent_term.put(@probe_cache_key, {verdict, System.monotonic_time(:millisecond) - 1})
    on_exit(fn -> :persistent_term.erase(@probe_cache_key) end)
  end

  defp prime_iterative_scan(code) do
    pt_key = {Loopctl.SystemConfig, "hnsw_iterative_scan"}
    :persistent_term.put(pt_key, code)
    on_exit(fn -> :persistent_term.erase(pt_key) end)
  end

  defp prime_max_scan_tuples(value) do
    pt_key = {Loopctl.SystemConfig, "hnsw_max_scan_tuples"}
    :persistent_term.put(pt_key, value)
    on_exit(fn -> :persistent_term.erase(pt_key) end)
  end

  # US-38.4: prime the live-tunable `SystemConfig "hnsw_ef_search"` cache directly (the
  # documented persistent_term key format) rather than `SystemConfig.put/2`, to avoid a
  # leaked DB row, and erase on exit. This module is `async: false` precisely BECAUSE this
  # mutates a VM-global key that concurrent cross-file ANN readers also read (see the
  # @moduledoc); the `[1, 1000]` clamp in `hnsw_ef_search/0` prevents pgvector raising on an
  # out-of-range GUC but provides NO cross-test isolation, so async isolation is what keeps a
  # primed value from bleeding into another file's recall. Mirrors the
  # `provider_admission_snooze_seconds` precedent in `provider/admission_test.exs` (which is
  # safe under `async: true` only because no concurrent file reads that key for real behavior).
  defp prime_ef_search(value) do
    pt_key = {Loopctl.SystemConfig, "hnsw_ef_search"}
    :persistent_term.put(pt_key, value)
    on_exit(fn -> :persistent_term.erase(pt_key) end)
  end

  describe "inconclusive probe classification (negative-cache eligibility)" do
    # The class decides whether an inconclusive probe is negative-cached. Sweeping every
    # Postgrex.Error into :transaction (the never-cached class) meant a REAL production
    # incident — statement timeouts, connection exhaustion, an admin shutdown — re-probed
    # and re-warned on every ANN read, which is the storm the cache exists to bound.
    test "only a poisoned-transaction SQLSTATE is :transaction; other backend errors are :pool" do
      poisoned = %Postgrex.Error{postgres: %{code: :in_failed_sql_transaction}}

      assert HeavyRead.inconclusive_class(poisoned) == :transaction,
             "25P02 is a harness artifact of an earlier failed statement, not backend pressure"

      for code <- [:query_canceled, :too_many_connections, :admin_shutdown, :crash_shutdown] do
        error = %Postgrex.Error{postgres: %{code: code}}

        assert HeavyRead.inconclusive_class(error) == :pool,
               "#{code} is backend pressure and MUST stay negative-cacheable"
      end
    end

    test "ownership errors keep their own class, and unknown failures default to :pool" do
      assert HeavyRead.inconclusive_class(%DBConnection.OwnershipError{}) == :ownership
      assert HeavyRead.inconclusive_class(%DBConnection.ConnectionError{}) == :pool
      assert HeavyRead.inconclusive_class(:some_exit_reason) == :pool
    end

    test "an {:error, _} tuple is unwrapped before classifying" do
      wrapped = {:error, %Postgrex.Error{postgres: %{code: :too_many_connections}}}

      assert HeavyRead.inconclusive_class(wrapped) == :pool
    end
  end

  describe "last conclusive verdict (probe-blip fallback)" do
    @last_conclusive_key {Loopctl.HeavyRead, :iterative_scan_last_conclusive}

    test "a conclusive probe records its verdict for later inconclusive reads to fall back on" do
      :persistent_term.erase(@probe_cache_key)
      :persistent_term.erase(@last_conclusive_key)
      on_exit(fn -> :persistent_term.erase(@last_conclusive_key) end)

      # Drives a real probe against the test backend.
      verdict = HeavyRead.iterative_scan_supported?()

      assert :persistent_term.get(@last_conclusive_key, :none) == verdict,
             "a conclusive probe must record what the backend actually said, so a later " <>
               "probe BLIP reuses it instead of silently reconfiguring the ANN read to the " <>
               "pgvector default OFF"
    end
  end
end
