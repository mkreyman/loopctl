defmodule LoopctlWeb.DBErrorMetricTest do
  @moduledoc """
  US-27.15 / TC-27.15.1 (AC-27.15.1): the db-error and under-fill events that feed the
  scale COUNTERS actually fire, carrying only BOUNDED, id-only payloads.

  This proves the COUNT SOURCES (not the Prometheus scrape — testing a running
  reporter is out of scope; the metric DEFINITIONS are asserted in
  `Loopctl.Telemetry.ScaleMetricsTest`):

    * forcing a `:query_canceled` (57014) through the REAL `DBErrorBackstop` path
      emits `[:loopctl, :db, :error]` once with `mapped_code: "db_statement_timeout"`,
      a 5-char `sqlstate`, and a BOUNDED `endpoint` (a `Controller.action` atom);
    * forcing a recall under-fill (reusing the US-27.6b dense-hub seam) emits
      `[:loopctl, :knowledge, :vector_search, :under_fill]` with an `endpoint`;
    * NEITHER payload contains a raw SQL / vector literal / bound param / body.

  The db-error path runs synchronously in the test process via
  `LoopctlWeb.Endpoint.call/2`, so a `self()`-scoped telemetry handler captures it
  without cross-test leakage in the async suite.
  """
  use LoopctlWeb.ConnCase, async: true

  import ExUnit.CaptureLog, only: [with_log: 1]

  alias Loopctl.HeavyReadRepo
  alias Loopctl.Knowledge
  alias Loopctl.Telemetry.ScaleMetrics
  alias Loopctl.TelemetryEvents

  setup :verify_on_exit!

  @dims 1536
  defp e(prefix), do: prefix ++ List.duplicate(0.0, @dims - length(prefix))

  # Attach a handler for `event`, forwarding ONLY events emitted from THIS test
  # process to the mailbox, with guaranteed detach.
  defp with_event_handler(event, fun) do
    test_pid = self()
    handler_id = "metric-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      event,
      fn ev, measurements, metadata, _ ->
        if self() == test_pid, do: send(test_pid, {:event, ev, measurements, metadata})
      end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(handler_id)
    end
  end

  defp authed_conn(conn) do
    tenant = fixture(:tenant)
    {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{raw_key}")
      |> Plug.Conn.assign(:current_api_key, %{tenant_id: tenant.id})

    {conn, tenant}
  end

  describe "db_statement_timeout (57014) increments the db-error counter source (TC-27.15.1)" do
    test "the [:loopctl, :db, :error] event fires with mapped_code + bounded endpoint, no leak",
         %{conn: conn} do
      {conn, tenant} = authed_conn(conn)
      conn = put_req_header(conn, "x-test-raise-db-error", "57014")

      with_event_handler(TelemetryEvents.db_error(), fn ->
        with_log(fn ->
          assert_raise LoopctlWeb.SanitizedDBError, fn ->
            LoopctlWeb.Endpoint.call(conn, [])
          end
        end)
      end)

      assert_received {:event, [:loopctl, :db, :error], measurements, metadata}

      # A pure increment.
      assert measurements.count == 1

      # The 57014 timeout class — the AC's counter — separated by mapped_code.
      assert metadata.mapped_code == "db_statement_timeout"
      assert metadata.sqlstate == "57014"

      # endpoint is a BOUNDED Controller.action atom (the matched route), never a raw
      # path with ids. The test router dispatches to a real controller.action.
      assert is_atom(metadata.endpoint)
      assert metadata.endpoint != :unknown

      # tenant_id rides in metadata (an id) for the cap-gated counter tag — but it is
      # an id, not content.
      assert metadata.tenant_id == tenant.id

      # No vector / body / raw SQL / param leaks into the metric payload (AC-27.15.3).
      flat = inspect({measurements, metadata})
      refute flat =~ "SELECT"
      refute flat =~ "::vector"
      refute flat =~ "embedding"
      refute flat =~ "0.123"

      # Exactly one event for the request.
      refute_received {:event, [:loopctl, :db, :error], _, _}
    end

    test "a serialization failure (40001) fires the same event with its own mapped_code",
         %{conn: conn} do
      {conn, _tenant} = authed_conn(conn)
      conn = put_req_header(conn, "x-test-raise-db-error", "40001")

      with_event_handler(TelemetryEvents.db_error(), fn ->
        with_log(fn ->
          assert_raise LoopctlWeb.SanitizedDBError, fn ->
            LoopctlWeb.Endpoint.call(conn, [])
          end
        end)
      end)

      assert_received {:event, [:loopctl, :db, :error], _measurements, metadata}
      assert metadata.mapped_code == "db_serialization_failure"
      assert metadata.sqlstate == "40001"
    end
  end

  describe "recall under-fill increments the under-fill counter source (TC-27.15.1)" do
    test "the under_fill event fires with an endpoint tag and no content leak" do
      tenant = fixture(:tenant)
      target = embedded(tenant.id, "Hub", [1.0, 0.0])

      # Dense hub: fill the (test) 6-row pool and pre-link all → the anti-join cuts the
      # result below limit, firing the under-fill signal (US-27.6b seam).
      neighbors = for i <- 1..6, do: embedded(tenant.id, "N#{i}", [1.0, 0.0])
      for n <- neighbors, do: link!(tenant.id, target.id, n.id)

      with_event_handler(TelemetryEvents.vector_search_under_fill(), fn ->
        {:ok, suggestions, _meta} =
          Knowledge.suggest_links_with_meta(tenant.id, target.id, limit: 5, threshold: 0.5)

        assert length(suggestions) < 5
      end)

      assert_received {:event, [:loopctl, :knowledge, :vector_search, :under_fill], measurements,
                       metadata}

      # The counter draws on :requested; the endpoint tag is the bounded :suggested_links.
      assert measurements.requested == 5
      assert metadata.endpoint == :suggested_links
      assert metadata.tenant_id == tenant.id

      # No vector / body leaks into the metric payload (AC-27.15.3).
      flat = inspect({measurements, metadata})
      refute flat =~ "1.0"
      refute flat =~ "::vector"
      refute flat =~ "embedding"
    end
  end

  describe "heavy-read latency metric source (US-27.15 drift-guard)" do
    test "the latency distribution subscribes to the event the REAL HeavyReadRepo fires" do
      # The latency metric subscribes to [:loopctl, :heavy_read_repo, :query], but in
      # :test HeavyRead's DI routes heavy reads to AdminRepo (a DIFFERENT event), so the
      # app code path never fires this exact event — an event-name / Ecto-prefix /
      # telemetry_options drift would silently leave the p95 alert empty. Fire the REAL
      # HeavyReadRepo query event end-to-end and assert the metric reads keys it carries.
      hist =
        Enum.find(ScaleMetrics.scale_metrics(), fn m ->
          m.name == [:loopctl, :heavy_read_repo, :query, :duration]
        end)

      assert hist.event_name == [:loopctl, :heavy_read_repo, :query]

      test_pid = self()
      handler = "hr-latency-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler,
        [:loopctl, :heavy_read_repo, :query],
        fn _e, meas, meta, _ ->
          if self() == test_pid, do: send(test_pid, {:hr_query, meas, meta})
        end,
        nil
      )

      try do
        HeavyReadRepo.query!(
          "SELECT version FROM schema_migrations LIMIT 1",
          [],
          telemetry_options: [endpoint: :semantic_search]
        )
      after
        :telemetry.detach(handler)
      end

      assert_received {:hr_query, meas, meta}
      # The metric reads measurement :total_time — it must be present on the real event.
      assert is_integer(meas.total_time)
      # And latency_tags/1 extracts a BOUNDED endpoint from the REAL metadata shape.
      assert ScaleMetrics.latency_tags(meta) == %{endpoint: :semantic_search}
    end
  end

  defp embedded(tenant_id, title, prefix) do
    a = fixture(:article, %{tenant_id: tenant_id, title: title, status: :published})
    {:ok, _} = Knowledge.update_embedding(tenant_id, a.id, e(prefix))
    a
  end

  defp link!(tenant_id, source_id, target_id) do
    fixture(:article_link, %{
      tenant_id: tenant_id,
      source_article_id: source_id,
      target_article_id: target_id,
      relationship_type: :relates_to
    })
  end
end
