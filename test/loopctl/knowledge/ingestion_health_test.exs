defmodule Loopctl.Knowledge.IngestionHealthTest do
  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  alias Loopctl.AdminRepo
  alias Loopctl.Audit.AuditLog
  alias Loopctl.Coordination.ChannelPost
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

  # No channel_post fixture exists (create_post/4 always stamps expires_at at now+30d),
  # so insert ChannelPost structs directly on the BYPASSRLS AdminRepo to control expires_at.
  defp channel_post(tenant_id, hours_offset) do
    project = fixture(:project, %{tenant_id: tenant_id})
    agent = fixture(:agent, %{tenant_id: tenant_id})

    %ChannelPost{
      tenant_id: tenant_id,
      project_id: project.id,
      agent_id: agent.id,
      body: "post",
      expires_at: DateTime.add(DateTime.utc_now(), hours_offset, :hour)
    }
    |> AdminRepo.insert!()
  end

  defp for_tenant(candidates, tenant_id),
    do: Enum.filter(candidates, &(&1.tenant_id == tenant_id))

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

    test "honors a per-source-type establishment threshold override" do
      tenant = fixture(:tenant)
      # Only 2 stale captures — below the global threshold of 5, but an override
      # lowers the bar for this low-volume-but-critical source_type.
      for _ <- 1..2, do: captured(tenant.id, "session_log", @stale_hours)

      candidates =
        IngestionHealth.detect(%{
          monitored_source_types: ["session_log"],
          established_threshold: 5,
          established_threshold_overrides: %{"session_log" => 2},
          staleness_threshold_hours: 72
        })
        |> Enum.filter(&(&1.tenant_id == tenant.id))

      assert [%{source_type: "session_log", sample_count: 2}] = candidates
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

    test "resolved: :all returns both resolved and unresolved" do
      tenant = fixture(:tenant)
      fixture(:ingestion_anomaly, %{tenant_id: tenant.id, source_type: "session_log"})

      fixture(:ingestion_anomaly, %{
        tenant_id: tenant.id,
        source_type: "manual",
        resolved: true
      })

      {:ok, %{total: default_total}} = IngestionHealth.list_anomalies(tenant.id)
      assert default_total == 1

      {:ok, %{total: all_total}} = IngestionHealth.list_anomalies(tenant.id, resolved: :all)
      assert all_total == 2
    end

    test "recomputes hours_stale for an unresolved anomaly at read time" do
      tenant = fixture(:tenant)
      # last_event_at 200h ago but a stale detection-time snapshot of only 80h.
      anomaly =
        fixture(:ingestion_anomaly, %{
          tenant_id: tenant.id,
          source_type: "session_log",
          hours_stale: 80,
          last_event_at: DateTime.add(DateTime.utc_now(), -200, :hour)
        })

      {:ok, %{data: [read]}} = IngestionHealth.list_anomalies(tenant.id)
      assert read.id == anomaly.id
      # Read-time recompute reports the TRUE current age (~200h), not the frozen 80h.
      assert read.hours_stale >= 199
    end
  end

  describe "unarchive_anomaly/3" do
    test "flips archived back to false and restores monitoring, with an audit entry" do
      tenant = fixture(:tenant)
      anomaly = fixture(:ingestion_anomaly, %{tenant_id: tenant.id, archived: true})

      assert {:ok, unarchived} =
               IngestionHealth.unarchive_anomaly(tenant.id, anomaly.id, actor_type: "api_key")

      assert unarchived.archived == false

      audit_count =
        from(a in AuditLog,
          where:
            a.tenant_id == ^tenant.id and a.entity_type == "ingestion_anomaly" and
              a.action == "unarchived" and a.entity_id == ^anomaly.id
        )
        |> AdminRepo.aggregate(:count)

      assert audit_count == 1
    end

    test "un-archiving a non-archived anomaly is an idempotent no-op (no bogus audit)" do
      tenant = fixture(:tenant)
      anomaly = fixture(:ingestion_anomaly, %{tenant_id: tenant.id, archived: false})

      assert {:ok, result} = IngestionHealth.unarchive_anomaly(tenant.id, anomaly.id)
      assert result.archived == false

      audit_count =
        from(a in AuditLog,
          where:
            a.tenant_id == ^tenant.id and a.entity_type == "ingestion_anomaly" and
              a.action == "unarchived"
        )
        |> AdminRepo.aggregate(:count)

      assert audit_count == 0
    end

    test "returns :not_found for another tenant's anomaly" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      anomaly = fixture(:ingestion_anomaly, %{tenant_id: tenant_a.id, archived: true})

      assert {:error, :not_found} = IngestionHealth.unarchive_anomaly(tenant_b.id, anomaly.id)
    end
  end

  describe "auto_resolve_recovered/0" do
    test "resolves an open anomaly whose captures have resumed" do
      tenant = fixture(:tenant)

      anomaly =
        fixture(:ingestion_anomaly, %{
          tenant_id: tenant.id,
          source_type: "session_log",
          last_event_at: DateTime.add(DateTime.utc_now(), -100, :hour)
        })

      # A capture ARRIVES after the anomaly's last_event_at → the stream recovered.
      captured(tenant.id, "session_log", 1)

      assert IngestionHealth.auto_resolve_recovered() >= 1

      {:ok, reloaded} = IngestionHealth.get_anomaly(tenant.id, anomaly.id)
      assert reloaded.resolved == true
    end

    test "leaves an open anomaly untouched while the source is still silent" do
      tenant = fixture(:tenant)

      anomaly =
        fixture(:ingestion_anomaly, %{
          tenant_id: tenant.id,
          source_type: "session_log",
          last_event_at: DateTime.add(DateTime.utc_now(), -100, :hour)
        })

      # Only OLD captures (older than last_event_at) — no recovery.
      captured(tenant.id, "session_log", 150)

      IngestionHealth.auto_resolve_recovered()

      {:ok, reloaded} = IngestionHealth.get_anomaly(tenant.id, anomaly.id)
      assert reloaded.resolved == false
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

  # --- PR B2: high-reject-rate detection off the ingestion_write_stats rollup ---

  describe "detect_high_reject_rate/0" do
    test "flags an established (>= min_attempts) high-reject source_type" do
      tenant = fixture(:tenant)

      # 10 attempts, 8 rejects (title_conflict) -> rate 0.8 > 0.5.
      fixture(:ingestion_write_stats, %{
        tenant_id: tenant.id,
        source_type: "web_article",
        created_count: 2,
        title_conflict_count: 8
      })

      candidates =
        IngestionHealth.detect_high_reject_rate()
        |> Enum.filter(&(&1.tenant_id == tenant.id))

      assert [candidate] = candidates
      assert candidate.anomaly_type == :high_reject_rate
      assert candidate.source_type == "web_article"
      assert candidate.total_attempts == 10
      assert candidate.rejects == 8
      assert candidate.reject_rate == 0.8
      assert candidate.window_days == 7
      assert candidate.dominant_reason == "title_conflict"
    end

    test "sums title_conflict + validation_error as rejects; picks the dominant reason" do
      tenant = fixture(:tenant)

      fixture(:ingestion_write_stats, %{
        tenant_id: tenant.id,
        source_type: "web_article",
        created_count: 2,
        title_conflict_count: 3,
        validation_error_count: 6
      })

      [candidate] =
        IngestionHealth.detect_high_reject_rate()
        |> Enum.filter(&(&1.tenant_id == tenant.id))

      assert candidate.total_attempts == 11
      assert candidate.rejects == 9
      assert candidate.dominant_reason == "validation_error"
    end

    test "does not flag below min_attempts" do
      tenant = fixture(:tenant)

      fixture(:ingestion_write_stats, %{
        tenant_id: tenant.id,
        source_type: "web_article",
        created_count: 1,
        title_conflict_count: 4
      })

      assert IngestionHealth.detect_high_reject_rate()
             |> Enum.filter(&(&1.tenant_id == tenant.id)) == []
    end

    test "does not flag when reject rate is at/below the threshold" do
      tenant = fixture(:tenant)

      fixture(:ingestion_write_stats, %{
        tenant_id: tenant.id,
        source_type: "web_article",
        created_count: 6,
        title_conflict_count: 4
      })

      assert IngestionHealth.detect_high_reject_rate()
             |> Enum.filter(&(&1.tenant_id == tenant.id)) == []
    end

    test "sums across days within the rolling window" do
      tenant = fixture(:tenant)

      # Two days inside the 7-day window, each 5 attempts / 4 rejects -> 10 / 8.
      fixture(:ingestion_write_stats, %{
        tenant_id: tenant.id,
        source_type: "web_article",
        day: Date.utc_today(),
        created_count: 1,
        title_conflict_count: 4
      })

      fixture(:ingestion_write_stats, %{
        tenant_id: tenant.id,
        source_type: "web_article",
        day: Date.add(Date.utc_today(), -3),
        created_count: 1,
        validation_error_count: 4
      })

      [candidate] =
        IngestionHealth.detect_high_reject_rate()
        |> Enum.filter(&(&1.tenant_id == tenant.id))

      assert candidate.total_attempts == 10
      assert candidate.rejects == 8
    end

    test "excludes rows older than the rolling window" do
      tenant = fixture(:tenant)

      # A high-reject bucket 10 days ago is outside the default 7-day window.
      fixture(:ingestion_write_stats, %{
        tenant_id: tenant.id,
        source_type: "web_article",
        day: Date.add(Date.utc_today(), -10),
        created_count: 2,
        title_conflict_count: 8
      })

      assert IngestionHealth.detect_high_reject_rate()
             |> Enum.filter(&(&1.tenant_id == tenant.id)) == []
    end

    test "flags a NULL/unstamped source_type bucket under the sentinel source_type" do
      tenant = fixture(:tenant)

      # source_type is optional on a KB write, so the majority of agent captures omit
      # it; a reject outage on those unstamped writes must NOT be a blind spot. The NULL
      # bucket is surfaced under the sentinel (non-null so it can persist as an anomaly).
      fixture(:ingestion_write_stats, %{
        tenant_id: tenant.id,
        source_type: nil,
        created_count: 2,
        title_conflict_count: 8
      })

      [candidate] =
        IngestionHealth.detect_high_reject_rate()
        |> Enum.filter(&(&1.tenant_id == tenant.id))

      assert candidate.source_type == IngestionHealth.unstamped_source_type()
      assert candidate.total_attempts == 10
      assert candidate.rejects == 8
    end

    test "folds NULL and empty-string source_type into ONE unstamped bucket" do
      tenant = fixture(:tenant)

      fixture(:ingestion_write_stats, %{
        tenant_id: tenant.id,
        source_type: nil,
        day: Date.utc_today(),
        created_count: 1,
        title_conflict_count: 4
      })

      fixture(:ingestion_write_stats, %{
        tenant_id: tenant.id,
        source_type: "",
        day: Date.add(Date.utc_today(), -1),
        created_count: 1,
        title_conflict_count: 4
      })

      [candidate] =
        IngestionHealth.detect_high_reject_rate()
        |> Enum.filter(&(&1.tenant_id == tenant.id))

      assert candidate.source_type == IngestionHealth.unstamped_source_type()
      assert candidate.total_attempts == 10
      assert candidate.rejects == 8
    end

    test "honors an explicit config passed to detect_high_reject_rate/1" do
      tenant = fixture(:tenant)

      # 6 attempts, 4 rejects -> rate 0.66; below default min_attempts 10 but an
      # explicit lower min_attempts + threshold flags it.
      fixture(:ingestion_write_stats, %{
        tenant_id: tenant.id,
        source_type: "web_article",
        created_count: 2,
        title_conflict_count: 4
      })

      candidates =
        IngestionHealth.detect_high_reject_rate(%{
          reject_rate_threshold: 0.5,
          min_attempts: 5,
          reject_window_days: 7
        })
        |> Enum.filter(&(&1.tenant_id == tenant.id))

      assert [%{source_type: "web_article"}] = candidates
    end

    test "tenant isolation — one tenant's rejects never surface for another" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)

      fixture(:ingestion_write_stats, %{
        tenant_id: tenant_a.id,
        source_type: "web_article",
        created_count: 2,
        title_conflict_count: 8
      })

      fixture(:ingestion_write_stats, %{
        tenant_id: tenant_b.id,
        source_type: "web_article",
        created_count: 8,
        title_conflict_count: 2
      })

      tenants =
        IngestionHealth.detect_high_reject_rate() |> Enum.map(& &1.tenant_id) |> Enum.uniq()

      assert tenant_a.id in tenants
      refute tenant_b.id in tenants
    end
  end

  describe "detect_sweep_stalled/0,1 (#498)" do
    test "returns a candidate per tenant holding rows expired beyond the grace window" do
      tenant = fixture(:tenant)
      channel_post(tenant.id, -24)
      channel_post(tenant.id, -10)
      # Still live — never counted.
      channel_post(tenant.id, 24)

      assert [candidate] = IngestionHealth.detect_sweep_stalled() |> for_tenant(tenant.id)

      assert candidate.anomaly_type == :sweep_stalled
      assert candidate.source_type == IngestionHealth.sweep_source_type()
      assert candidate.overdue_count == 2
      # hours_stale reports the TRUE age of the oldest overdue row, not the threshold.
      assert candidate.hours_stale >= 24
      assert candidate.grace_hours == IngestionHealth.sweep_staleness_hours()
      assert %DateTime{} = candidate.oldest_expires_at
    end

    test "ignores rows still inside the grace window" do
      tenant = fixture(:tenant)
      channel_post(tenant.id, -1)

      assert IngestionHealth.detect_sweep_stalled() |> for_tenant(tenant.id) == []
    end

    test "honors an explicit grace window without touching app env" do
      tenant = fixture(:tenant)
      channel_post(tenant.id, -3)

      assert IngestionHealth.detect_sweep_stalled(%{sweep_staleness_hours: 6})
             |> for_tenant(tenant.id) == []

      assert [_] =
               IngestionHealth.detect_sweep_stalled(%{sweep_staleness_hours: 1})
               |> for_tenant(tenant.id)
    end

    test "skips non-active tenants and is tenant-scoped" do
      active = fixture(:tenant)
      suspended = fixture(:tenant, %{status: :suspended})

      channel_post(active.id, -24)
      channel_post(suspended.id, -24)

      candidates = IngestionHealth.detect_sweep_stalled()

      assert [_] = for_tenant(candidates, active.id)
      assert for_tenant(candidates, suspended.id) == []
    end

    test "detection is PURE — no anomaly rows are written" do
      tenant = fixture(:tenant)
      channel_post(tenant.id, -24)

      assert [_] = IngestionHealth.detect_sweep_stalled() |> for_tenant(tenant.id)

      assert IngestionAnomaly
             |> where([a], a.tenant_id == ^tenant.id)
             |> AdminRepo.all() == []
    end

    # The false-page guard: the sweeper is bounded (1000 rows/run, 12 runs/hour), so
    # residue at least as large as what it could have deleted in the elapsed window is a
    # BACKLOG being drained, not a stall.
    test "does not flag residue the bounded sweep could not yet have drained" do
      tenant = fixture(:tenant)
      channel_post(tenant.id, -12)

      # 0 rows/hour of capacity => the sweep could not have removed ANY of this residue,
      # so its age is fully explained by the backlog rather than by a dead sweep.
      assert IngestionHealth.detect_sweep_stalled(%{
               sweep_staleness_hours: 6,
               sweep_hard_stale_hours: 24,
               sweep_drain_rate_per_hour: 0,
               sweep_scan_limit: 50_000
             })
             |> for_tenant(tenant.id) == []
    end

    test "flags residue the sweep had ample capacity to drain" do
      tenant = fixture(:tenant)
      channel_post(tenant.id, -12)

      assert [_] =
               IngestionHealth.detect_sweep_stalled(%{
                 sweep_staleness_hours: 6,
                 sweep_hard_stale_hours: 24,
                 # 288k rows of capacity over 24h vs one overdue row: the sweep had ample
                 # room to delete it and did not => it is not running.
                 sweep_drain_rate_per_hour: 12_000,
                 sweep_scan_limit: 50_000
               })
               |> for_tenant(tenant.id)
    end

    test "the hard ceiling flags an undrainable backlog regardless of drain capacity" do
      tenant = fixture(:tenant)
      channel_post(tenant.id, -48)

      assert [candidate] =
               IngestionHealth.detect_sweep_stalled(%{
                 sweep_staleness_hours: 6,
                 sweep_hard_stale_hours: 24,
                 sweep_drain_rate_per_hour: 12_000,
                 sweep_scan_limit: 50_000
               })
               |> for_tenant(tenant.id)

      assert candidate.hours_stale >= 48
    end

    # A TRUNCATED scan proves the residue is at least sweep_scan_limit — larger than any
    # sub-ceiling drain capacity — so it is backlog, not a stall. It also proves the read
    # is BOUNDED: the cross-tenant aggregate never scans an unbounded overdue backlog on
    # the small AdminRepo pool.
    test "a truncated (capped) scan is treated as backlog, not a stall" do
      tenant = fixture(:tenant)
      channel_post(tenant.id, -12)

      assert IngestionHealth.detect_sweep_stalled(%{
               sweep_staleness_hours: 6,
               sweep_hard_stale_hours: 24,
               sweep_drain_rate_per_hour: 12_000,
               # One row scanned == the cap => truncated.
               sweep_scan_limit: 1
             })
             |> for_tenant(tenant.id) == []
    end
  end

  describe "source_type_seen?/2" do
    test "the sweep sentinel always reports seen (it names a detector, not a stream)" do
      tenant = fixture(:tenant)

      assert IngestionHealth.source_type_seen?(tenant.id, IngestionHealth.sweep_source_type())
    end

    test "true when the tenant has a write-stats row for the source_type" do
      tenant = fixture(:tenant)
      fixture(:ingestion_write_stats, %{tenant_id: tenant.id, source_type: "web_article"})

      assert IngestionHealth.source_type_seen?(tenant.id, "web_article")
    end

    test "false for a never-seen source_type (and is tenant-scoped)" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      fixture(:ingestion_write_stats, %{tenant_id: tenant_a.id, source_type: "web_article"})

      refute IngestionHealth.source_type_seen?(tenant_a.id, "never_seen")
      # Tenant B never recorded web_article.
      refute IngestionHealth.source_type_seen?(tenant_b.id, "web_article")
    end
  end
end
