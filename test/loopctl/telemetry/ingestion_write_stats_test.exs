defmodule Loopctl.Telemetry.IngestionWriteStatsTest do
  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.Knowledge.IngestionWriteStats
  alias Loopctl.TelemetryEvents

  # The handler is attached once at app boot (Loopctl.Application) and runs
  # synchronously in the emitting (test) process, so it shares this test's sandbox
  # connection — emitting the event here writes a rollup row we can read back.
  defp emit(tenant_id, source_type, outcome) do
    :telemetry.execute(
      TelemetryEvents.article_write(),
      %{count: 1},
      %{tenant_id: tenant_id, source_type: source_type, outcome: outcome}
    )
  end

  defp stats_for(tenant_id, source_type) do
    query =
      from(s in IngestionWriteStats,
        where: s.tenant_id == ^tenant_id and s.day == ^Date.utc_today()
      )

    query =
      if is_nil(source_type),
        do: where(query, [s], is_nil(s.source_type)),
        else: where(query, [s], s.source_type == ^source_type)

    AdminRepo.one(query)
  end

  describe "article_write telemetry -> ingestion_write_stats rollup" do
    test "increments the matching counter per outcome" do
      tenant = fixture(:tenant)

      emit(tenant.id, "session_log", :created)
      emit(tenant.id, "session_log", :created)
      emit(tenant.id, "session_log", :deduplicated)
      emit(tenant.id, "session_log", :gated_to_draft)
      emit(tenant.id, "session_log", :title_conflict)
      emit(tenant.id, "session_log", :title_conflict)
      emit(tenant.id, "session_log", :validation_error)

      row = stats_for(tenant.id, "session_log")

      assert row.created_count == 2
      assert row.deduplicated_count == 1
      assert row.drafted_count == 1
      assert row.title_conflict_count == 2
      assert row.validation_error_count == 1
    end

    test "buckets a NULL source_type distinctly from a named source_type" do
      tenant = fixture(:tenant)

      emit(tenant.id, nil, :created)
      emit(tenant.id, nil, :title_conflict)
      emit(tenant.id, "session_log", :created)

      null_row = stats_for(tenant.id, nil)
      named_row = stats_for(tenant.id, "session_log")

      assert null_row.source_type == nil
      assert null_row.created_count == 1
      assert null_row.title_conflict_count == 1

      assert named_row.source_type == "session_log"
      assert named_row.created_count == 1
      assert named_row.title_conflict_count == 0
    end

    test "an unknown outcome is skipped (no row written)" do
      tenant = fixture(:tenant)

      emit(tenant.id, "session_log", :some_future_outcome)

      assert stats_for(tenant.id, "session_log") == nil
    end

    test "an event with no tenant_id is skipped" do
      # Nothing to attribute -> no write, no crash.
      :telemetry.execute(
        TelemetryEvents.article_write(),
        %{count: 1},
        %{tenant_id: nil, source_type: "session_log", outcome: :created}
      )

      assert AdminRepo.aggregate(IngestionWriteStats, :count, :id) == 0
    end

    test "tenant isolation — each tenant's counters are separate" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)

      emit(tenant_a.id, "session_log", :title_conflict)
      emit(tenant_b.id, "session_log", :created)

      a_row = stats_for(tenant_a.id, "session_log")
      b_row = stats_for(tenant_b.id, "session_log")

      assert a_row.title_conflict_count == 1
      assert a_row.created_count == 0
      assert b_row.created_count == 1
      assert b_row.title_conflict_count == 0
    end
  end
end
