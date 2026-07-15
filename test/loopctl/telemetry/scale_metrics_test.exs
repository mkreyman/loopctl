defmodule Loopctl.Telemetry.ScaleMetricsTest do
  @moduledoc """
  US-27.15 / TC-27.15.2 (AC-27.15.3): the scale metrics carry NO sensitive content
  and have CONCRETELY bounded label cardinality.

  This is the test that PROVES the label set cannot grow unboundedly:

    * every scale metric's `tags` ⊆ `{:endpoint, :mapped_code, :tenant_id}` — there is
      no `:article_id`, no raw-vector / body / param tag;
    * the latency DISTRIBUTION has NO `:tenant_id` tag (endpoint × tenant × buckets is
      the multi-tenant cardinality bomb the AC forbids);
    * the tenant-label cap gate: with the `:persistent_term` gate OFF (over cap),
      `scale_tags/1` collapses `tenant_id` to the fixed `:_aggregated` sentinel
      (cardinality 1); with it ON (≤ cap), the real `tenant_id` is included.

  It also pins the test-env contract that the APP's Prometheus reporter
  (`Loopctl.Telemetry.MetricsReporter` / the `:prometheus_metrics` singleton) is NOT a
  started child in `:test` (no `:9568` bind) while `metrics/0` still returns the scale
  defs.

  Mostly pure metric-definition / `tag_values` inspection — no DB. The US-33.1
  queue_time "reporter round-trip" describe (and the US-34.4 one below it) are the
  exceptions: they boot a REAL, privately-named `TelemetryMetricsPrometheus.Core`
  instance (never the app's `:9568`-bound singleton) to prove the
  definitions/`tag_values`/measurement wiring actually record and scrape correctly,
  rather than asserting `:telemetry.execute/3 == :ok` against zero attached
  handlers (which the framework guarantees regardless of whether the code under
  test is correct).

  US-34.4 adds ten counters wiring emitted-but-dead events (LLM/embedding-blocked,
  index-health, secrets/witness/memory-promotion degradation signals) into
  Prometheus — see `@allowed_tags`/`@scale_metric_names` below and
  `Loopctl.Telemetry.ScaleMetrics`'s moduledoc "Wiring emitted-but-dead events" for
  the full inventory, including the events deliberately left out of scope.

  `async: false` (R2 review): the cap-gate tests MUTATE the process-global
  `:persistent_term` gate (`{ScaleMetrics, :tenant_label?}`), which is shared across the
  whole VM. Running concurrently with another async test that reads the gate (e.g. via
  `scale_tags/1`) could make that test observe the flipped value mid-run. Matching the
  project's existing async:false precedent for shared-global-state tests.
  """
  use ExUnit.Case, async: false

  alias Loopctl.Telemetry.ScaleMetrics

  @scale_metric_names [
    "loopctl.db.error.count",
    "loopctl.heavy_read_repo.query.duration",
    "loopctl.knowledge.vector_search.under_fill.count",
    "loopctl.knowledge.semantic_fallback.count",
    "loopctl.knowledge.hybrid_provenance.count",
    "loopctl.repo.checkout.queue_time",
    "loopctl.admin_repo.checkout.queue_time",
    "loopctl.llm.blocked.count",
    "loopctl.embedding.skipped_no_key.count",
    "loopctl.index_health.invalid.count",
    "loopctl.secrets.orphan_cleanup_failed.count",
    "loopctl.witness.divergence.count",
    "loopctl.witness.bootstrap_already_consumed.count",
    "loopctl.memory_promotion.failed.count",
    "loopctl.memory_promotion.degraded.count",
    "loopctl.memory_promotion.quota_exceeded.count",
    "loopctl.memory_promotion.budget_exceeded.count",
    "loopctl.oban.jobs.count",
    "loopctl.oban.jobs.executing_orphan.count",
    "loopctl.oban.poll.error.count",
    "loopctl.ingestion.backlog_gate.failed_open.count",
    "loopctl.knowledge.article_linking.corpus_size",
    "loopctl.cluster.peers.count"
  ]

  # The ONLY labels any scale metric may ever carry (AC-27.15.3). Anything outside this
  # set — especially an unbounded `:article_id` or a raw vector/body — is a hard fail.
  # `:reason` (#297 semantic-fallback counter; US-34.4's witness-divergence counter) is
  # a BOUNDED, sanitized tag set (never a key/body/query), so it is a safe dimension.
  # `:provenance` (`"curated"`/`"retrieved"`) and `:hit` (`true`/`false`) — US-31.2's
  # hybrid-provenance counter — are likewise small, fixed-cardinality dimensions.
  # `:repo` (US-33.1) is a static, fixed 2-value tag ("repo"/"admin_repo") — the repo
  # identity is encoded in the event name, not read from metadata. US-34.4 adds:
  # `:operation`/`:provider` (llm.blocked — bounded 4-value op enum + 2-value
  # provider), `:source` (embedding.skipped_no_key — "article"/"memory"), `:index`/
  # `:purpose`/`:state` (index_health.invalid — three bounded fixed sets), `:op`
  # (secrets.orphan_cleanup_failed — normalized `:delete`/`:restore`/`:unknown`), and
  # `:stage` (memory_promotion.failed — bounded `:compile`/`:persist`/`:enqueue`). US-34.1
  # adds `:poller` (oban.poll.error.count — bounded `:queue_state`/`:executing_orphans`)
  # and `:error_class` (oban.poll.error.count — CLASSIFIED, never a raw exception).
  @allowed_tags MapSet.new([
                  :endpoint,
                  :mapped_code,
                  :tenant_id,
                  :reason,
                  :provenance,
                  :hit,
                  :repo,
                  :operation,
                  :provider,
                  :source,
                  :index,
                  :purpose,
                  :state,
                  :op,
                  :stage,
                  :state,
                  :queue,
                  :poller,
                  :error_class,
                  # US-38.3: clustering-readiness peer gauge — bounded 3-value status
                  # (`:single_node`/`:clustered`/`:expected_peers_missing`), never a node name.
                  :status
                ])

  defp scale_metrics, do: ScaleMetrics.scale_metrics()

  defp metric(name) do
    Enum.find(scale_metrics(), fn m -> Enum.join(m.name, ".") == name end) ||
      flunk("scale metric #{name} not found")
  end

  describe "scale_metrics/0 — bounded, safe label set (TC-27.15.2, AC-27.15.3)" do
    test "exactly the expected scale metrics are defined" do
      names = Enum.map(scale_metrics(), &Enum.join(&1.name, "."))
      assert Enum.sort(names) == Enum.sort(@scale_metric_names)
    end

    test "every scale metric's tags are a subset of {endpoint, mapped_code, tenant_id}" do
      for m <- scale_metrics() do
        tags = MapSet.new(m.tags)

        assert MapSet.subset?(tags, @allowed_tags),
               "#{Enum.join(m.name, ".")} has out-of-bounds tags: " <>
                 "#{inspect(MapSet.difference(tags, @allowed_tags) |> MapSet.to_list())}"
      end
    end

    test "no scale metric carries an :article_id (or any per-article / vector / body) tag" do
      forbidden = [:article_id, :id, :embedding, :vector, :body, :params, :query]

      for m <- scale_metrics(), tag <- m.tags do
        refute tag in forbidden,
               "#{Enum.join(m.name, ".")} carries forbidden tag #{inspect(tag)}"
      end
    end

    test "the latency DISTRIBUTION is tagged by endpoint ONLY — never tenant_id" do
      hist = metric("loopctl.heavy_read_repo.query.duration")

      assert %Telemetry.Metrics.Distribution{} = hist
      assert hist.tags == [:endpoint]
      refute :tenant_id in hist.tags
      refute :mapped_code in hist.tags
    end

    test "the two counters DO admit tenant_id as a (cap-gated) tag" do
      db_error = metric("loopctl.db.error.count")
      under_fill = metric("loopctl.knowledge.vector_search.under_fill.count")

      assert %Telemetry.Metrics.Counter{} = db_error
      assert :tenant_id in db_error.tags
      assert :mapped_code in db_error.tags
      assert :endpoint in db_error.tags

      assert %Telemetry.Metrics.Counter{} = under_fill
      assert :tenant_id in under_fill.tags
      assert :endpoint in under_fill.tags
    end

    test "the semantic-fallback counter (#297) is tagged by :reason ONLY — never tenant_id" do
      counter = metric("loopctl.knowledge.semantic_fallback.count")

      assert %Telemetry.Metrics.Counter{} = counter
      assert counter.tags == [:reason]
      refute :tenant_id in counter.tags
      refute :endpoint in counter.tags

      # `reason` is a fixed, small label set (no cap gate needed); a missing reason
      # collapses to a bounded sentinel, never blank.
      assert ScaleMetrics.semantic_fallback_tags(%{reason: "no_embedding_key"}) == %{
               reason: "no_embedding_key"
             }

      assert ScaleMetrics.semantic_fallback_tags(%{}) == %{reason: "unknown"}
    end

    test "the article-linking corpus-size gauge (US-36.4) is a last_value tagged by tenant_id ONLY" do
      gauge = metric("loopctl.knowledge.article_linking.corpus_size")

      assert %Telemetry.Metrics.LastValue{} = gauge
      assert gauge.tags == [:tenant_id]
      assert gauge.measurement == :total
      # The unbounded per-article/project ids in the event metadata are NEVER labels.
      refute :article_id in gauge.tags
      refute :project_id in gauge.tags

      # tenant_id reuses the SAME cap-gated sentinel collapse as the other scale counters
      # (exercised under a controlled gate in the "tenant-label cap gate" describe below).
      assert ScaleMetrics.article_linking_corpus_size_tags(%{
               tenant_id: "t-1",
               article_id: "a-1",
               project_id: "p-1"
             })
             |> Map.keys() == [:tenant_id]
    end

    test "the hybrid-provenance counter (US-31.2) is tagged by provenance, hit, and tenant_id" do
      counter = metric("loopctl.knowledge.hybrid_provenance.count")

      assert %Telemetry.Metrics.Counter{} = counter
      assert MapSet.new(counter.tags) == MapSet.new([:provenance, :hit, :tenant_id])

      # Defaults are bounded/never blank when metadata is missing keys (tenant_id's
      # gated value is exercised separately in the "tenant-label cap gate" describe,
      # which explicitly controls the gate so this assertion isn't order-dependent).
      assert ScaleMetrics.hybrid_provenance_tags(%{}).provenance == "unknown"
      refute ScaleMetrics.hybrid_provenance_tags(%{}).hit
    end

    test "histogram buckets are the documented bounded set" do
      hist = metric("loopctl.heavy_read_repo.query.duration")

      assert hist.reporter_options[:buckets] == [
               10,
               50,
               100,
               250,
               500,
               1_000,
               2_500,
               5_000,
               10_000
             ]
    end
  end

  describe "tenant-label cap gate — the cardinality proof (AC-27.15.3)" do
    setup do
      # The gate lives in process-global :persistent_term. Snapshot + restore so this
      # test can flip it without leaking into a concurrent async test that reads it.
      original = ScaleMetrics.tenant_label?()
      on_exit(fn -> :persistent_term.put({ScaleMetrics, :tenant_label?}, original) end)
      :ok
    end

    defp gate_off, do: :persistent_term.put({ScaleMetrics, :tenant_label?}, false)
    defp gate_on, do: :persistent_term.put({ScaleMetrics, :tenant_label?}, true)

    test "gate OFF (over cap): scale_tags/1 collapses tenant_id to the :_aggregated sentinel" do
      gate_off()

      tags =
        ScaleMetrics.scale_tags(%{
          endpoint: :suggested_links,
          mapped_code: "db_error",
          tenant_id: "t-123"
        })

      assert tags.tenant_id == :_aggregated
      assert tags.tenant_id == ScaleMetrics.aggregated_sentinel()
      # The real tenant id is NOT present anywhere — only the bounded sentinel.
      refute tags.tenant_id == "t-123"
      assert tags.endpoint == :suggested_links
      assert tags.mapped_code == "db_error"
    end

    test "gate ON (<= cap): scale_tags/1 includes the real tenant_id" do
      gate_on()

      tags =
        ScaleMetrics.scale_tags(%{
          endpoint: :suggested_links,
          mapped_code: "db_error",
          tenant_id: "t-123"
        })

      assert tags.tenant_id == "t-123"
    end

    test "gate ON but tenant_id missing/nil still collapses to the sentinel (never blank)" do
      gate_on()

      assert ScaleMetrics.scale_tags(%{endpoint: :x, mapped_code: "y"}).tenant_id == :_aggregated

      assert ScaleMetrics.scale_tags(%{endpoint: :x, mapped_code: "y", tenant_id: nil}).tenant_id ==
               :_aggregated
    end

    test "hybrid_provenance_tags/1 reuses the SAME cap-gated tenant_id collapse" do
      gate_off()

      assert ScaleMetrics.hybrid_provenance_tags(%{
               provenance: "curated",
               hit: true,
               tenant_id: "t-123"
             }) == %{provenance: "curated", hit: true, tenant_id: :_aggregated}

      gate_on()

      assert ScaleMetrics.hybrid_provenance_tags(%{
               provenance: "retrieved",
               hit: false,
               tenant_id: "t-123"
             }) == %{provenance: "retrieved", hit: false, tenant_id: "t-123"}
    end

    test "article_linking_corpus_size_tags/1 reuses the SAME cap-gated tenant_id collapse" do
      gate_off()

      assert ScaleMetrics.article_linking_corpus_size_tags(%{
               tenant_id: "t-123",
               article_id: "a-1",
               project_id: "p-1"
             }) == %{tenant_id: :_aggregated}

      gate_on()

      assert ScaleMetrics.article_linking_corpus_size_tags(%{
               tenant_id: "t-123",
               article_id: "a-1",
               project_id: "p-1"
             }) == %{tenant_id: "t-123"}
    end

    test "tenant_id over the cap is bounded to cardinality 1 across many distinct tenants" do
      gate_off()

      distinct =
        for i <- 1..1_000 do
          ScaleMetrics.scale_tags(%{endpoint: :e, mapped_code: "c", tenant_id: "tenant-#{i}"}).tenant_id
        end
        |> Enum.uniq()

      # 1000 distinct tenant ids → a SINGLE label value when gated off (provably bounded).
      assert distinct == [:_aggregated]
    end

    test "defaults: unseeded gate reads false (safe/bounded), cap is the documented 1000" do
      # Force the unseeded-read path by deleting the key, then restore in on_exit.
      :persistent_term.erase({ScaleMetrics, :tenant_label?})
      refute ScaleMetrics.tenant_label?()

      assert ScaleMetrics.scale_tags(%{endpoint: :e, mapped_code: "c", tenant_id: "t"}).tenant_id ==
               :_aggregated

      assert ScaleMetrics.tenant_label_cap() == 1_000
    end
  end

  describe "per-pool checkout queue_time distributions (US-33.1, TC-33.1.1)" do
    test "the Repo pool queue_time distribution is defined, in milliseconds, tagged by repo" do
      dist = metric("loopctl.repo.checkout.queue_time")

      assert %Telemetry.Metrics.Distribution{} = dist
      assert dist.event_name == [:loopctl, :repo, :query]
      assert is_function(dist.measurement, 1)
      assert dist.unit == :millisecond
      assert dist.tags == [:repo]
    end

    test "the AdminRepo pool queue_time distribution is defined, in milliseconds, tagged by repo" do
      dist = metric("loopctl.admin_repo.checkout.queue_time")

      assert %Telemetry.Metrics.Distribution{} = dist
      assert dist.event_name == [:loopctl, :admin_repo, :query]
      assert is_function(dist.measurement, 1)
      assert dist.unit == :millisecond
      assert dist.tags == [:repo]
    end

    test "both distributions use the documented sub-second checkout-wait buckets" do
      for name <- ["loopctl.repo.checkout.queue_time", "loopctl.admin_repo.checkout.queue_time"] do
        dist = metric(name)

        assert dist.reporter_options[:buckets] == [1, 5, 10, 25, 50, 100, 250, 500, 1_000]
      end
    end
  end

  describe "queue_time tag_values — static, defensive, bounded (TC-33.1.2/.3)" do
    test "queue_time_tags_repo/1 always returns the static %{repo: \"repo\"} map" do
      assert ScaleMetrics.queue_time_tags_repo(%{}) == %{repo: "repo"}

      assert ScaleMetrics.queue_time_tags_repo(%{
               tenant_id: "t-123",
               query: "SELECT 1",
               source: "stories"
             }) == %{repo: "repo"}
    end

    test "queue_time_tags_admin_repo/1 always returns the static %{repo: \"admin_repo\"} map" do
      assert ScaleMetrics.queue_time_tags_admin_repo(%{}) == %{repo: "admin_repo"}

      assert ScaleMetrics.queue_time_tags_admin_repo(%{
               tenant_id: "t-456",
               query: "SELECT 1"
             }) == %{repo: "admin_repo"}
    end

    test "tag cardinality is bounded to :repo only — no tenant/query tags (TC-33.1.3)" do
      for name <- ["loopctl.repo.checkout.queue_time", "loopctl.admin_repo.checkout.queue_time"] do
        dist = metric(name)

        assert dist.tags == [:repo]
        refute :tenant_id in dist.tags
        refute :query in dist.tags
      end
    end
  end

  describe "queue_time reporter round-trip — a REAL Prometheus reporter, not a no-handler no-op (TC-33.1.2, raw finding #3)" do
    # R2 review: the prior version of this describe only asserted `:telemetry.execute/3
    # == :ok` with ZERO handlers attached in :test — that assertion holds even if the
    # two distributions were deleted or `tag_values` raised, so it proved nothing about
    # the reporter path it was named for. These tests boot a REAL
    # `TelemetryMetricsPrometheus.Core` reporter (a private, uniquely-named instance —
    # NOT the app's `:prometheus_metrics` singleton, so this never binds `:9568` or
    # collides with `Loopctl.Telemetry.MetricsReporter`), attach the two queue_time
    # distributions to it, emit REAL Ecto-shaped measurement maps, and assert the
    # SCRAPE reflects the recorded value — proof the definitions, `tag_values` fns, and
    # measurement wiring are all correct end to end, and that the reporter process
    # survives both the present-value and the absent-value (dropped) path.
    #
    # `start_async: false` forces metric registration to happen synchronously inside
    # `init/1` (the default `start_async: true` defers it to a `handle_info` message),
    # so the handlers are guaranteed attached before `start_supervised!/2` returns —
    # otherwise the very first `:telemetry.execute/3` below would race the async attach.
    setup do
      reporter_name = :"scale_metrics_queue_time_test_#{System.unique_integer([:positive])}"

      metrics = [
        metric("loopctl.repo.checkout.queue_time"),
        metric("loopctl.admin_repo.checkout.queue_time")
      ]

      pid =
        start_supervised!(
          {TelemetryMetricsPrometheus.Core,
           [metrics: metrics, name: reporter_name, start_async: false]}
        )

      %{reporter: reporter_name, reporter_pid: pid}
    end

    test "a Repo query WITH queue_time present is recorded and scraped, reporter survives",
         %{reporter: reporter, reporter_pid: pid} do
      :telemetry.execute(
        [:loopctl, :repo, :query],
        %{queue_time: 5_000_000, query_time: 1_000_000, total_time: 6_000_000},
        %{}
      )

      scrape = TelemetryMetricsPrometheus.Core.scrape(reporter)

      # 5_000_000 native ticks -> 5.0ms, landing (cumulatively) in the le="5" bucket and
      # every bucket above it, +Inf included — this is the ACTUAL aggregation output,
      # not a framework no-op.
      assert scrape =~ ~s(loopctl_repo_checkout_queue_time_bucket{repo="repo",le="1"} 0)
      assert scrape =~ ~s(loopctl_repo_checkout_queue_time_bucket{repo="repo",le="5"} 1)
      assert scrape =~ ~s(loopctl_repo_checkout_queue_time_bucket{repo="repo",le="+Inf"} 1)
      assert scrape =~ ~s(loopctl_repo_checkout_queue_time_sum{repo="repo"} 5.0)
      assert scrape =~ ~s(loopctl_repo_checkout_queue_time_count{repo="repo"} 1)

      assert Process.alive?(pid)
    end

    test "an AdminRepo query WITHOUT queue_time (in-transaction hot path) is dropped, not raised — reporter survives (raw finding #5)",
         %{reporter: reporter, reporter_pid: pid} do
      # This is the shape Ecto emits for every query AFTER the first inside
      # `AdminRepo.transaction/1` (the connection is already checked out, so `queue_time`
      # is OMITTED entirely from measurements) — precisely the 5-AdminRepo-query auth hot
      # path US-33.1 targets. `get_measurement/3` returns `{:measurement_not_found,
      # :queue_time}`, which `handle_event/4` routes to `Logger.debug` and drops (no
      # crash, no sample recorded).
      :telemetry.execute(
        [:loopctl, :admin_repo, :query],
        %{query_time: 500_000, total_time: 500_000},
        %{}
      )

      scrape = TelemetryMetricsPrometheus.Core.scrape(reporter)

      # No sample was ever recorded for this metric, so the Exporter emits NOTHING for
      # it (not even the HELP/TYPE header) — distinct, explicit proof of the drop, not
      # merely "no crash".
      refute scrape =~ "loopctl_admin_repo_checkout_queue_time"

      assert Process.alive?(pid)

      # The Repo distribution (a different metric on the SAME reporter) is unaffected by
      # the AdminRepo drop — proves the drop is isolated to the one series, not a
      # reporter-wide failure.
      :telemetry.execute(
        [:loopctl, :repo, :query],
        %{queue_time: 1_000_000, query_time: 100_000, total_time: 1_100_000},
        %{}
      )

      assert TelemetryMetricsPrometheus.Core.scrape(reporter) =~
               ~s(loopctl_repo_checkout_queue_time_count{repo="repo"} 1)
    end
  end

  describe "latency_tags/1 — endpoint from heavy-read options, no tenant" do
    test "reads endpoint from metadata.options[:endpoint]" do
      assert ScaleMetrics.latency_tags(%{options: [endpoint: :semantic_search]}) == %{
               endpoint: :semantic_search
             }
    end

    test "defaults to :unknown when no endpoint option is present" do
      assert ScaleMetrics.latency_tags(%{options: []}) == %{endpoint: :unknown}
      assert ScaleMetrics.latency_tags(%{}) == %{endpoint: :unknown}
    end

    test "carries NO tenant_id even if one leaks into metadata" do
      tags = ScaleMetrics.latency_tags(%{options: [endpoint: :novelty], tenant_id: "t-9"})
      refute Map.has_key?(tags, :tenant_id)
    end
  end

  describe "llm.blocked counter (US-34.4, AC-34.4.1, TC-34.4.1)" do
    test "the counter is defined, tagged by operation and provider only" do
      counter = metric("loopctl.llm.blocked.count")

      assert %Telemetry.Metrics.Counter{} = counter
      assert counter.event_name == [:loopctl, :llm, :blocked]
      assert MapSet.new(counter.tags) == MapSet.new([:operation, :provider])
      refute :tenant_id in counter.tags
    end

    test "llm.blocked increments a counter (TC-34.4.1): :telemetry.execute runs the handler without error" do
      reporter_name = :"llm_blocked_test_#{System.unique_integer([:positive])}"
      counter = metric("loopctl.llm.blocked.count")

      pid =
        start_supervised!(
          {TelemetryMetricsPrometheus.Core,
           [metrics: [counter], name: reporter_name, start_async: false]}
        )

      :telemetry.execute([:loopctl, :llm, :blocked], %{count: 1}, %{provider: "anthropic"})

      scrape = TelemetryMetricsPrometheus.Core.scrape(reporter_name)

      assert scrape =~
               ~s(loopctl_llm_blocked_count{operation="unknown",provider="anthropic"} 1)

      assert Process.alive?(pid)
    end

    test "llm_blocked_tags/1 defaults missing operation/provider to \"unknown\", never tenant_id" do
      assert ScaleMetrics.llm_blocked_tags(%{}) == %{operation: "unknown", provider: "unknown"}

      assert ScaleMetrics.llm_blocked_tags(%{operation: :embedding, provider: "embedding"}) == %{
               operation: :embedding,
               provider: "embedding"
             }

      tags = ScaleMetrics.llm_blocked_tags(%{operation: :extraction, tenant_id: "t-1"})
      refute Map.has_key?(tags, :tenant_id)
    end
  end

  describe "embedding.skipped_no_key counter (US-34.4, AC-34.4.1, TC-34.4.2)" do
    test "the counter is defined, tagged by source only" do
      counter = metric("loopctl.embedding.skipped_no_key.count")

      assert %Telemetry.Metrics.Counter{} = counter
      assert counter.event_name == [:loopctl, :embedding, :skipped_no_key]
      assert counter.tags == [:source]
    end

    test "embedding_skipped_tags/1 defaults a missing source to \"unknown\", never tags ids/tenant_id" do
      assert ScaleMetrics.embedding_skipped_tags(%{}) == %{source: "unknown"}
      assert ScaleMetrics.embedding_skipped_tags(%{source: "article"}) == %{source: "article"}

      tags =
        ScaleMetrics.embedding_skipped_tags(%{
          source: "memory",
          tenant_id: "t-1",
          memory_id: "m-1"
        })

      assert tags == %{source: "memory"}
    end
  end

  describe "index_health.invalid counter (US-34.4, AC-34.4.1, TC-34.4.2)" do
    test "the counter is defined, tagged by index/purpose/state" do
      counter = metric("loopctl.index_health.invalid.count")

      assert %Telemetry.Metrics.Counter{} = counter
      assert counter.event_name == [:loopctl, :index_health, :invalid]
      assert MapSet.new(counter.tags) == MapSet.new([:index, :purpose, :state])
    end

    test "index_health_tags/1 passes through present keys and defaults missing ones to \"unknown\"" do
      assert ScaleMetrics.index_health_tags(%{
               index: "articles_embedding_idx",
               purpose: "vector_search",
               state: :invalid
             }) == %{index: "articles_embedding_idx", purpose: "vector_search", state: :invalid}

      assert ScaleMetrics.index_health_tags(%{}) == %{
               index: "unknown",
               purpose: "unknown",
               state: "unknown"
             }
    end
  end

  describe "secrets.orphan_cleanup_failed counter (US-34.4, AC-34.4.2)" do
    test "the counter is defined, tagged by op and reason only — never secret_name" do
      counter = metric("loopctl.secrets.orphan_cleanup_failed.count")

      assert %Telemetry.Metrics.Counter{} = counter
      assert counter.event_name == [:loopctl, :secrets, :orphan_cleanup_failed]
      assert MapSet.new(counter.tags) == MapSet.new([:op, :reason])
      refute :secret_name in counter.tags
    end

    test "secrets_orphan_cleanup_tags/1 normalizes op and CLASSIFIES reason (never raw free-text)" do
      assert ScaleMetrics.secrets_orphan_cleanup_tags(%{
               op: :restore,
               reason: :old_value_unavailable
             }) == %{op: :restore, reason: "old_value_unavailable"}

      assert ScaleMetrics.secrets_orphan_cleanup_tags(%{op: :delete, reason: :fly_not_configured}) ==
               %{op: :delete, reason: "fly_not_configured"}

      assert ScaleMetrics.secrets_orphan_cleanup_tags(%{op: :delete, reason: {:http_error, 503}}) ==
               %{op: :delete, reason: "http_error"}

      # A raw Fly GraphQL error payload is free-text — classified to a bounded
      # sentinel, never passed through as a label.
      assert ScaleMetrics.secrets_orphan_cleanup_tags(%{
               op: :restore,
               reason: {:fly_api_error, [%{"message" => "arbitrary free text from Fly"}]}
             }) == %{op: :restore, reason: "fly_api_error"}

      # An unrecognized/unbounded shape (e.g. a raw transport-error struct) still
      # collapses to the bounded "other" sentinel rather than ever leaking through.
      assert ScaleMetrics.secrets_orphan_cleanup_tags(%{
               op: :delete,
               reason: %{unexpected: "shape"}
             }) == %{op: :delete, reason: "other"}

      assert ScaleMetrics.secrets_orphan_cleanup_tags(%{}) == %{op: :unknown, reason: "unknown"}

      # secret_name is never present in the returned tags even if it leaks into metadata.
      tags =
        ScaleMetrics.secrets_orphan_cleanup_tags(%{
          op: :delete,
          reason: :fly_not_configured,
          secret_name: "tenant_audit_key_123"
        })

      refute Map.has_key?(tags, :secret_name)
    end
  end

  describe "witness.divergence counter (US-34.4, AC-34.4.2)" do
    test "the counter is defined, tagged by reason ONLY — never tenant_id/position" do
      counter = metric("loopctl.witness.divergence.count")

      assert %Telemetry.Metrics.Counter{} = counter
      assert counter.event_name == [:loopctl, :witness, :divergence]
      assert counter.tags == [:reason]
    end

    test "witness_divergence_tags/1 defaults a missing reason to \"unknown\", never tags tenant_id/position" do
      assert ScaleMetrics.witness_divergence_tags(%{reason: "prefix_mismatch"}) == %{
               reason: "prefix_mismatch"
             }

      assert ScaleMetrics.witness_divergence_tags(%{}) == %{reason: "unknown"}

      tags =
        ScaleMetrics.witness_divergence_tags(%{
          reason: "future_position",
          tenant_id: "t-1",
          position: 42
        })

      assert tags == %{reason: "future_position"}
    end
  end

  describe "witness.bootstrap_already_consumed counter (US-34.4, AC-34.4.2)" do
    test "the counter is defined, UNTAGGED — its only metadata (tenant_id) is never a label" do
      counter = metric("loopctl.witness.bootstrap_already_consumed.count")

      assert %Telemetry.Metrics.Counter{} = counter
      assert counter.event_name == [:loopctl, :witness, :bootstrap_already_consumed]
      assert counter.tags == []
    end
  end

  describe "memory_promotion.{failed,degraded,quota_exceeded,budget_exceeded} counters (US-34.4, AC-34.4.2)" do
    test "the :failed counter is tagged by :stage ONLY" do
      counter = metric("loopctl.memory_promotion.failed.count")

      assert %Telemetry.Metrics.Counter{} = counter
      assert counter.event_name == [:loopctl, :memory_promotion, :failed]
      assert counter.tags == [:stage]
    end

    test "the :degraded, :quota_exceeded, and :budget_exceeded counters are UNTAGGED" do
      for {name, event} <- [
            {"loopctl.memory_promotion.degraded.count", [:loopctl, :memory_promotion, :degraded]},
            {"loopctl.memory_promotion.quota_exceeded.count",
             [:loopctl, :memory_promotion, :quota_exceeded]},
            {"loopctl.memory_promotion.budget_exceeded.count",
             [:loopctl, :memory_promotion, :budget_exceeded]}
          ] do
        counter = metric(name)

        assert %Telemetry.Metrics.Counter{} = counter
        assert counter.event_name == event
        assert counter.tags == []
      end
    end

    test "memory_promotion_failed_tags/1 defaults a missing stage to \"unknown\", never tags tenant_id" do
      assert ScaleMetrics.memory_promotion_failed_tags(%{stage: :compile}) == %{stage: :compile}
      assert ScaleMetrics.memory_promotion_failed_tags(%{}) == %{stage: "unknown"}

      tags =
        ScaleMetrics.memory_promotion_failed_tags(%{
          stage: :enqueue,
          tenant_id: "t-1",
          subject_id: "s-1",
          session_id: "sess-1"
        })

      assert tags == %{stage: :enqueue}
    end
  end

  describe "US-34.4 reporter round-trip — real Prometheus scrape, not a no-handler no-op" do
    setup do
      reporter_name = :"scale_metrics_us_34_4_test_#{System.unique_integer([:positive])}"

      metrics = [
        metric("loopctl.embedding.skipped_no_key.count"),
        metric("loopctl.index_health.invalid.count"),
        metric("loopctl.secrets.orphan_cleanup_failed.count"),
        metric("loopctl.witness.divergence.count"),
        metric("loopctl.witness.bootstrap_already_consumed.count"),
        metric("loopctl.memory_promotion.failed.count"),
        metric("loopctl.memory_promotion.degraded.count"),
        metric("loopctl.memory_promotion.quota_exceeded.count"),
        metric("loopctl.memory_promotion.budget_exceeded.count")
      ]

      pid =
        start_supervised!(
          {TelemetryMetricsPrometheus.Core,
           [metrics: metrics, name: reporter_name, start_async: false]}
        )

      %{reporter: reporter_name, reporter_pid: pid}
    end

    test "each new counter records and scrapes end to end", %{
      reporter: reporter,
      reporter_pid: pid
    } do
      :telemetry.execute(
        [:loopctl, :embedding, :skipped_no_key],
        %{count: 1},
        %{tenant_id: "t-1", article_id: "a-1", source: "article"}
      )

      :telemetry.execute(
        [:loopctl, :index_health, :invalid],
        %{count: 1},
        %{index: "articles_embedding_idx", purpose: "vector_search", state: :invalid}
      )

      :telemetry.execute(
        [:loopctl, :secrets, :orphan_cleanup_failed],
        %{count: 1},
        %{op: :restore, secret_name: "k", reason: :old_value_unavailable}
      )

      :telemetry.execute(
        [:loopctl, :witness, :divergence],
        %{count: 1},
        %{tenant_id: "t-1", position: 1, reason: "prefix_mismatch"}
      )

      :telemetry.execute(
        [:loopctl, :witness, :bootstrap_already_consumed],
        %{count: 1},
        %{tenant_id: "t-1"}
      )

      :telemetry.execute(
        [:loopctl, :memory_promotion, :failed],
        %{count: 1},
        %{tenant_id: "t-1", subject_id: "s-1", session_id: "sess-1", stage: :compile}
      )

      :telemetry.execute(
        [:loopctl, :memory_promotion, :degraded],
        %{count: 1},
        %{tenant_id: "t-1", subject_id: "s-1", session_id: "sess-1"}
      )

      :telemetry.execute(
        [:loopctl, :memory_promotion, :quota_exceeded],
        %{count: 1},
        %{tenant_id: "t-1", subject_id: "s-1", session_id: "sess-1"}
      )

      :telemetry.execute(
        [:loopctl, :memory_promotion, :budget_exceeded],
        %{count: 1},
        %{tenant_id: "t-1", subject_id: "s-1", session_id: "sess-1"}
      )

      scrape = TelemetryMetricsPrometheus.Core.scrape(reporter)

      assert scrape =~ ~s(loopctl_embedding_skipped_no_key_count{source="article"} 1)

      assert scrape =~
               ~s(loopctl_index_health_invalid_count{index="articles_embedding_idx",purpose="vector_search",state="invalid"} 1)

      assert scrape =~
               ~s(loopctl_secrets_orphan_cleanup_failed_count{op="restore",reason="old_value_unavailable"} 1)

      assert scrape =~ ~s(loopctl_witness_divergence_count{reason="prefix_mismatch"} 1)
      assert scrape =~ ~s(loopctl_witness_bootstrap_already_consumed_count 1)
      assert scrape =~ ~s(loopctl_memory_promotion_failed_count{stage="compile"} 1)
      assert scrape =~ ~s(loopctl_memory_promotion_degraded_count 1)
      assert scrape =~ ~s(loopctl_memory_promotion_quota_exceeded_count 1)
      assert scrape =~ ~s(loopctl_memory_promotion_budget_exceeded_count 1)

      assert Process.alive?(pid)
    end
  end

  describe "Oban queue/state + executing_orphan gauges (US-34.1, AC-34.1.1/.2/.5)" do
    test "loopctl.oban.jobs.count is a last_value GAUGE tagged by state and queue ONLY" do
      gauge = metric("loopctl.oban.jobs.count")

      assert %Telemetry.Metrics.LastValue{} = gauge
      assert gauge.event_name == [:loopctl, :oban, :jobs, :count]
      assert MapSet.new(gauge.tags) == MapSet.new([:state, :queue])
      refute :tenant_id in gauge.tags
    end

    test "loopctl.oban.jobs.executing_orphan.count is a last_value GAUGE, UNTAGGED" do
      gauge = metric("loopctl.oban.jobs.executing_orphan.count")

      assert %Telemetry.Metrics.LastValue{} = gauge
      assert gauge.event_name == [:loopctl, :oban, :jobs, :executing_orphan, :count]
      assert gauge.tags == []
    end

    test "oban_queue_state_tags/1 passes through present state/queue, defaults missing to \"unknown\"" do
      assert ScaleMetrics.oban_queue_state_tags(%{state: "available", queue: "default"}) == %{
               state: "available",
               queue: "default"
             }

      assert ScaleMetrics.oban_queue_state_tags(%{}) == %{state: "unknown", queue: "unknown"}
    end

    test "oban_queue_state_tags/1 never tags tenant_id even if one leaks into metadata" do
      tags =
        ScaleMetrics.oban_queue_state_tags(%{
          state: "executing",
          queue: "webhooks",
          tenant_id: "t-1"
        })

      refute Map.has_key?(tags, :tenant_id)
    end

    test "poller config accessors default to the documented bounded values" do
      assert ScaleMetrics.oban_metrics_poll_statement_timeout_ms() == 2_000
      assert ScaleMetrics.oban_metrics_orphan_threshold_minutes() == 45
    end

    test "validate_positive_poll_timeout!/1 raises ArgumentError on a non-positive-integer value (review finding — unit-tested directly, never mutating global config)" do
      for bad <- ["2000", -1, 0, nil] do
        assert_raise ArgumentError,
                     ~r/oban_metrics_poll_statement_timeout_ms/,
                     fn -> ScaleMetrics.validate_positive_poll_timeout!(bad) end
      end
    end

    test "validate_positive_poll_timeout!/1 passes through a positive integer unchanged" do
      assert ScaleMetrics.validate_positive_poll_timeout!(5_000) == 5_000
    end

    test "oban_states/0 returns Oban.Job.states/0's full 8-value enum (review finding: was documented as 7)" do
      assert ScaleMetrics.oban_states() == Oban.Job.states()
      assert length(ScaleMetrics.oban_states()) == 8
    end

    test "oban_active_states/0 excludes only the terminal completed/discarded/cancelled states (review finding)" do
      active = ScaleMetrics.oban_active_states()

      assert length(active) == 5
      assert :completed not in active
      assert :discarded not in active
      assert :cancelled not in active
      assert :available in active
      assert :scheduled in active
      assert :executing in active
      assert :retryable in active
      assert :suspended in active
    end

    test "oban_queues/0 returns the configured queue names, resolved at call time" do
      configured =
        :loopctl
        |> Application.get_env(Oban, [])
        |> Keyword.get(:queues, [])
        |> Keyword.keys()

      assert ScaleMetrics.oban_queues() == configured
      # US-36.1 added `:ingestion` and `:verification`, taking the queue count 9 -> 11.
      assert length(ScaleMetrics.oban_queues()) == 11
    end

    test "queues_from_config/1 resolves to [] instead of raising on the documented `queues: false` shape (review finding — unit-tested directly, never mutating global config)" do
      assert ScaleMetrics.queues_from_config(false) == []
      assert ScaleMetrics.queues_from_config(nil) == []
    end

    test "queues_from_config/1 passes a valid queues keyword through to its keys" do
      assert ScaleMetrics.queues_from_config(default: 10, webhooks: 5) == [:default, :webhooks]
    end

    test "oban_poll_error_tags/1 CLASSIFIES the raw exception into a small bounded set (review finding — never the raw exception message/struct)" do
      assert ScaleMetrics.oban_poll_error_tags(%{
               poller: :queue_state,
               exception: %Postgrex.Error{}
             }) == %{poller: :queue_state, error_class: "db_error"}

      assert ScaleMetrics.oban_poll_error_tags(%{
               poller: :queue_state,
               exception: %DBConnection.ConnectionError{}
             }) == %{poller: :queue_state, error_class: "db_error"}

      assert ScaleMetrics.oban_poll_error_tags(%{
               poller: :queue_state,
               exception: %DBConnection.OwnershipError{}
             }) == %{poller: :queue_state, error_class: "db_error"}

      assert ScaleMetrics.oban_poll_error_tags(%{
               poller: :queue_state,
               exception: %ArgumentError{}
             }) == %{poller: :queue_state, error_class: "config_error"}

      assert ScaleMetrics.oban_poll_error_tags(%{
               poller: :executing_orphans,
               exception: %FunctionClauseError{}
             }) == %{poller: :executing_orphans, error_class: "config_error"}

      assert ScaleMetrics.oban_poll_error_tags(%{
               poller: :queue_state,
               exception: %RuntimeError{}
             }) == %{poller: :queue_state, error_class: "other"}
    end

    test "oban_poll_error_tags/1 defaults missing keys to \"unknown\", never raises" do
      assert ScaleMetrics.oban_poll_error_tags(%{}) == %{
               poller: "unknown",
               error_class: "unknown"
             }
    end

    test "loopctl.oban.poll.error.count is a COUNTER tagged by poller and error_class (review finding)" do
      counter = metric("loopctl.oban.poll.error.count")

      assert %Telemetry.Metrics.Counter{} = counter
      assert counter.event_name == [:loopctl, :oban, :poll, :error]
      assert MapSet.new(counter.tags) == MapSet.new([:poller, :error_class])
    end

    # The DB-backed zero-fill / drain-to-zero behavior of poll_oban_queue_state/0
    # itself is covered in oban_metrics_poller_test.exs (TC-34.1.1b/c), which uses
    # `Loopctl.DataCase` for `Loopctl.Repo` sandbox isolation — this file is
    # intentionally pure/no-DB (see moduledoc), so it only covers the fixed
    # matrix inputs (`oban_states/0`/`oban_active_states/0`/`oban_queues/0`) here.

    test "the reporter round-trip: both gauges record and scrape end to end" do
      reporter_name = :"scale_metrics_oban_gauges_test_#{System.unique_integer([:positive])}"

      metrics = [
        metric("loopctl.oban.jobs.count"),
        metric("loopctl.oban.jobs.executing_orphan.count")
      ]

      pid =
        start_supervised!(
          {TelemetryMetricsPrometheus.Core,
           [metrics: metrics, name: reporter_name, start_async: false]}
        )

      :telemetry.execute([:loopctl, :oban, :jobs, :count], %{count: 3}, %{
        state: "available",
        queue: "default"
      })

      :telemetry.execute(
        [:loopctl, :oban, :jobs, :executing_orphan, :count],
        %{count: 1},
        %{}
      )

      scrape = TelemetryMetricsPrometheus.Core.scrape(reporter_name)

      # TelemetryMetricsPrometheus renders tags in ALPHABETICAL order, not
      # declaration order — `queue` before `state`.
      assert scrape =~ ~s(loopctl_oban_jobs_count{queue="default",state="available"} 3)
      assert scrape =~ ~s(loopctl_oban_jobs_executing_orphan_count 1)
      assert Process.alive?(pid)
    end
  end

  describe "metrics/0 wiring + test-env reporter guard" do
    test "LoopctlWeb.Telemetry.metrics/0 includes all scale metrics" do
      names = Enum.map(LoopctlWeb.Telemetry.metrics(), &Enum.join(&1.name, "."))
      for scale_name <- @scale_metric_names, do: assert(scale_name in names)
    end

    test "the Prometheus reporter is NOT a started child in :test (no :9568 bind)" do
      refute Application.get_env(:loopctl, :metrics_reporter_enabled, false),
             "metrics_reporter_enabled must stay false in :test so the suite never binds :9568"

      children = Supervisor.which_children(LoopctlWeb.Telemetry)
      child_ids = Enum.map(children, fn {id, _pid, _type, _mods} -> id end)

      # The reporter is supervised through the `Loopctl.Telemetry.MetricsReporter`
      # wrapper, so THAT module is the child id to look for. (The old assertion checked
      # `TelemetryMetricsPrometheus`, whose own child id is its `:name` — so the refute
      # could never fail and gave false confidence.)
      refute Enum.any?(child_ids, &(&1 == Loopctl.Telemetry.MetricsReporter)),
             "the metrics reporter wrapper must not be supervised in :test"

      # Nothing is listening on the metrics port in test.
      assert {:error, :econnrefused} =
               :gen_tcp.connect(~c"127.0.0.1", 9568, [:binary, active: false], 200)
    end

    test "ScaleAlerts is NOT auto-started in :test (no background timers / ETS table)" do
      refute Application.get_env(:loopctl, :scale_alerts_enabled, false),
             "scale_alerts_enabled must stay false in :test so the suite never auto-runs " <>
               "ScaleAlerts timers or owns its ETS table"

      children = Supervisor.which_children(LoopctlWeb.Telemetry)
      child_ids = Enum.map(children, fn {id, _pid, _type, _mods} -> id end)

      refute Enum.any?(child_ids, &(&1 == Loopctl.Telemetry.ScaleAlerts)),
             "ScaleAlerts must not be supervised in :test (tests start it directly)"

      # The default ScaleAlerts ETS table is not owned by anyone in :test.
      assert :ets.info(:loopctl_scale_alerts) == :undefined
    end
  end

  describe "cluster-readiness peer gauge (US-38.3, AC-38.3.2)" do
    test "the gauge is a last_value tagged by :status ONLY (bounded, no node names)" do
      gauge = metric("loopctl.cluster.peers.count")

      assert %Telemetry.Metrics.LastValue{} = gauge
      assert gauge.tags == [:status]
      refute :tenant_id in gauge.tags
    end

    test "cluster_peers_tags/1 emits ONLY the bounded status (defaults missing to \"unknown\")" do
      assert ScaleMetrics.cluster_peers_tags(%{status: :single_node}) == %{status: :single_node}
      assert ScaleMetrics.cluster_peers_tags(%{status: :clustered}) == %{status: :clustered}
      assert ScaleMetrics.cluster_peers_tags(%{}) == %{status: "unknown"}
    end

    test "poll_cluster_readiness/0 emits the peer-count gauge with the readiness status and returns :ok" do
      ref = make_ref()
      handler_id = {:cluster_peers_test, ref}
      parent = self()

      :telemetry.attach(
        handler_id,
        [:loopctl, :cluster, :peers],
        fn _event, measurements, metadata, _cfg ->
          send(parent, {:cluster_peers, ref, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert :ok == ScaleMetrics.poll_cluster_readiness()

      assert_receive {:cluster_peers, ^ref, %{count: count}, %{status: status}}
      # On the (single) test node this is the 'clustering not required' state — a
      # peer COUNT (never a node-name list) and a bounded status.
      assert is_integer(count)
      assert status in [:single_node, :clustered, :expected_peers_missing]
    end
  end
end
