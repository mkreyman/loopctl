defmodule Loopctl.Knowledge.IngestionHealthTest do
  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  alias Loopctl.AdminRepo
  alias Loopctl.Audit.AuditLog
  alias Loopctl.Knowledge.IngestionAnomaly
  alias Loopctl.Knowledge.IngestionHealth

  import Ecto.Query

  @stale_hours 96
  @fresh_hours 1

  defp captured(tenant_id, source_type, hours_ago) do
    captured_article(%{
      tenant_id: tenant_id,
      source_type: source_type,
      status: :published,
      inserted_at: DateTime.add(DateTime.utc_now(), -hours_ago, :hour)
    })
  end

  describe "detect/0" do
    test "returns a candidate for an established + stale source_type" do
      tenant = fixture(:tenant)
      for _ <- 1..5, do: captured(tenant.id, "session_log", @stale_hours)

      candidates = IngestionHealth.detect()

      assert [%{tenant_id: tid, source_type: "session_log"} = candidate] =
               Enum.filter(candidates, &(&1.tenant_id == tenant.id))

      assert tid == tenant.id
      assert candidate.sample_count == 5
      assert candidate.hours_stale >= 72
      assert %DateTime{} = candidate.last_event_at
    end

    test "returns no candidate for a fresh source_type" do
      tenant = fixture(:tenant)
      for _ <- 1..5, do: captured(tenant.id, "session_log", @fresh_hours)

      assert IngestionHealth.detect() |> Enum.filter(&(&1.tenant_id == tenant.id)) == []
    end

    test "returns no candidate below the established threshold" do
      tenant = fixture(:tenant)
      for _ <- 1..4, do: captured(tenant.id, "session_log", @stale_hours)

      assert IngestionHealth.detect() |> Enum.filter(&(&1.tenant_id == tenant.id)) == []
    end

    test "honors an explicit config passed to detect/1" do
      tenant = fixture(:tenant)
      for _ <- 1..3, do: captured(tenant.id, "session_log", @stale_hours)

      # Lower the established threshold so 3 samples qualify.
      candidates =
        IngestionHealth.detect(%{
          monitored_source_types: ["session_log"],
          established_threshold: 3,
          staleness_threshold_hours: 72
        })
        |> Enum.filter(&(&1.tenant_id == tenant.id))

      assert length(candidates) == 1
    end

    test "tenant isolation — a stale tenant does not surface another tenant's data" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)

      for _ <- 1..5, do: captured(tenant_a.id, "session_log", @stale_hours)
      for _ <- 1..5, do: captured(tenant_b.id, "session_log", @fresh_hours)

      candidate_tenants =
        IngestionHealth.detect() |> Enum.map(& &1.tenant_id) |> Enum.uniq()

      assert tenant_a.id in candidate_tenants
      refute tenant_b.id in candidate_tenants
    end

    test "monitored_source_types :all flags any established + stale source_type" do
      tenant = fixture(:tenant)
      # "newsletter" is NOT in the test-env narrow monitoring list, so it is only
      # flagged when detect/1 is given `:all` (the prod default).
      for _ <- 1..5, do: captured(tenant.id, "newsletter", @stale_hours)

      cfg = %{
        monitored_source_types: :all,
        established_threshold: 5,
        staleness_threshold_hours: 72
      }

      candidates = IngestionHealth.detect(cfg) |> Enum.filter(&(&1.tenant_id == tenant.id))

      assert [%{source_type: "newsletter"}] = candidates
    end

    test "recency window excludes a wound-down source_type silent past the window" do
      tenant = fixture(:tenant)
      # Established long ago (well beyond the establishment window) and silent since:
      # a legitimately wound-down workflow, NOT a fresh regression — must not flag.
      for _ <- 1..5, do: captured(tenant.id, "session_log", 24 * 60)

      cfg = %{
        monitored_source_types: ["session_log"],
        established_threshold: 5,
        staleness_threshold_hours: 72,
        # 30-day window; captures 60 days old age out of establishment.
        establishment_window_hours: 720
      }

      assert IngestionHealth.detect(cfg) |> Enum.filter(&(&1.tenant_id == tenant.id)) == []
    end
  end

  describe "IngestionAnomaly.create_changeset/2 invariants" do
    test "rejects sample_count 0 (never established) and hours_stale 0 (not stale)" do
      base = %{
        source_type: "session_log",
        anomaly_type: :capture_silence,
        hours_stale: 96,
        sample_count: 5
      }

      refute IngestionAnomaly.create_changeset(%IngestionAnomaly{}, %{base | sample_count: 0}).valid?

      refute IngestionAnomaly.create_changeset(%IngestionAnomaly{}, %{base | hours_stale: 0}).valid?

      assert IngestionAnomaly.create_changeset(%IngestionAnomaly{}, base).valid?
    end
  end

  describe "list_anomalies/2" do
    test "excludes resolved and archived by default" do
      tenant = fixture(:tenant)

      unresolved =
        fixture(:ingestion_anomaly, %{tenant_id: tenant.id, source_type: "session_log"})

      _resolved =
        fixture(:ingestion_anomaly, %{
          tenant_id: tenant.id,
          source_type: "manual",
          resolved: true
        })

      _archived =
        fixture(:ingestion_anomaly, %{
          tenant_id: tenant.id,
          source_type: "newsletter",
          archived: true
        })

      {:ok, %{data: data, total: total}} = IngestionHealth.list_anomalies(tenant.id)

      assert total == 1
      assert [%{id: id}] = data
      assert id == unresolved.id
    end

    test "filters by source_type" do
      tenant = fixture(:tenant)
      fixture(:ingestion_anomaly, %{tenant_id: tenant.id, source_type: "session_log"})
      fixture(:ingestion_anomaly, %{tenant_id: tenant.id, source_type: "newsletter"})

      {:ok, %{data: data, total: total}} =
        IngestionHealth.list_anomalies(tenant.id, source_type: "session_log")

      assert total == 1
      assert hd(data).source_type == "session_log"
    end

    test "tenant isolation — never returns another tenant's anomalies" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      fixture(:ingestion_anomaly, %{tenant_id: tenant_a.id})

      {:ok, %{data: data, total: total}} = IngestionHealth.list_anomalies(tenant_b.id)

      assert data == []
      assert total == 0
    end
  end

  describe "resolve_anomaly/3" do
    test "flips resolved and writes an audit entry" do
      tenant = fixture(:tenant)
      anomaly = fixture(:ingestion_anomaly, %{tenant_id: tenant.id})

      assert {:ok, resolved} =
               IngestionHealth.resolve_anomaly(tenant.id, anomaly.id, actor_type: "api_key")

      assert resolved.resolved == true

      audit_count =
        from(a in AuditLog,
          where:
            a.tenant_id == ^tenant.id and a.entity_type == "ingestion_anomaly" and
              a.action == "resolved" and a.entity_id == ^anomaly.id
        )
        |> AdminRepo.aggregate(:count)

      assert audit_count == 1
    end

    test "returns :not_found for another tenant's anomaly" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      anomaly = fixture(:ingestion_anomaly, %{tenant_id: tenant_a.id})

      assert {:error, :not_found} = IngestionHealth.resolve_anomaly(tenant_b.id, anomaly.id)
    end

    test "returns :not_found for a non-existent anomaly" do
      tenant = fixture(:tenant)

      assert {:error, :not_found} =
               IngestionHealth.resolve_anomaly(tenant.id, Ecto.UUID.generate())
    end

    test "re-resolving an already-resolved anomaly is an idempotent no-op (no bogus audit)" do
      tenant = fixture(:tenant)
      anomaly = fixture(:ingestion_anomaly, %{tenant_id: tenant.id, resolved: true})

      assert {:ok, resolved} = IngestionHealth.resolve_anomaly(tenant.id, anomaly.id)
      assert resolved.resolved == true

      # No `false -> true` audit transition is written for a row already resolved.
      audit_count =
        from(a in AuditLog,
          where:
            a.tenant_id == ^tenant.id and a.entity_type == "ingestion_anomaly" and
              a.action == "resolved" and a.entity_id == ^anomaly.id
        )
        |> AdminRepo.aggregate(:count)

      assert audit_count == 0
    end
  end

  describe "archive_anomaly/3" do
    test "flips archived and writes an audit entry" do
      tenant = fixture(:tenant)
      anomaly = fixture(:ingestion_anomaly, %{tenant_id: tenant.id})

      assert {:ok, archived} =
               IngestionHealth.archive_anomaly(tenant.id, anomaly.id, actor_type: "api_key")

      assert archived.archived == true

      audit_count =
        from(a in AuditLog,
          where:
            a.tenant_id == ^tenant.id and a.entity_type == "ingestion_anomaly" and
              a.action == "archived" and a.entity_id == ^anomaly.id
        )
        |> AdminRepo.aggregate(:count)

      assert audit_count == 1
    end

    test "re-archiving an already-archived anomaly is an idempotent no-op" do
      tenant = fixture(:tenant)
      anomaly = fixture(:ingestion_anomaly, %{tenant_id: tenant.id, archived: true})

      assert {:ok, archived} = IngestionHealth.archive_anomaly(tenant.id, anomaly.id)
      assert archived.archived == true

      audit_count =
        from(a in AuditLog,
          where:
            a.tenant_id == ^tenant.id and a.entity_type == "ingestion_anomaly" and
              a.action == "archived" and a.entity_id == ^anomaly.id
        )
        |> AdminRepo.aggregate(:count)

      assert audit_count == 0
    end

    test "returns :not_found for another tenant's anomaly" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      anomaly = fixture(:ingestion_anomaly, %{tenant_id: tenant_a.id})

      assert {:error, :not_found} = IngestionHealth.archive_anomaly(tenant_b.id, anomaly.id)
    end
  end
end
