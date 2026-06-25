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

  It also pins the test-env contract that the Prometheus reporter is NOT a started
  child in `:test` (no `:9568` bind) while `metrics/0` still returns the scale defs.

  Pure metric-definition / `tag_values` inspection — no DB, no running server.

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
    "loopctl.knowledge.vector_search.under_fill.count"
  ]

  # The ONLY labels any scale metric may ever carry (AC-27.15.3). Anything outside this
  # set — especially an unbounded `:article_id` or a raw vector/body — is a hard fail.
  @allowed_tags MapSet.new([:endpoint, :mapped_code, :tenant_id])

  defp scale_metrics, do: ScaleMetrics.scale_metrics()

  defp metric(name) do
    Enum.find(scale_metrics(), fn m -> Enum.join(m.name, ".") == name end) ||
      flunk("scale metric #{name} not found")
  end

  describe "scale_metrics/0 — bounded, safe label set (TC-27.15.2, AC-27.15.3)" do
    test "exactly the three scale metrics are defined" do
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

  describe "metrics/0 wiring + test-env reporter guard" do
    test "LoopctlWeb.Telemetry.metrics/0 includes the three scale metrics" do
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
end
