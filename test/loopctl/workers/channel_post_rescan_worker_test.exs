defmodule Loopctl.Workers.ChannelPostRescanWorkerTest do
  use Loopctl.DataCase, async: true
  use Oban.Testing, repo: Loopctl.Repo

  setup :verify_on_exit!

  import Ecto.Query
  import ExUnit.CaptureLog

  alias Loopctl.AdminRepo
  alias Loopctl.Audit.AuditLog
  alias Loopctl.Coordination
  alias Loopctl.Coordination.ChannelPost
  alias Loopctl.Knowledge.IngestionAnomaly
  alias Loopctl.TelemetryEvents
  alias Loopctl.Workers.ChannelPostRescanWorker
  alias Loopctl.Workers.ScaleAlertDeliveryWorker

  # A denylisted loopctl-key shape (`lc_` + >= 20 chars). Fake, but matched by
  # Loopctl.Security.SecretDenylist exactly as a real one would be.
  @secret "lc_abcdefghijklmnopqrstuvwxyz012345"

  # Telemetry handlers are GLOBAL and async tests run concurrently, so every assertion
  # below filters on a per-test-unique `limit` (carried in the run-event metadata) or on
  # this test's tenant id (the per-hit event) — a concurrent emitter of the same event
  # can never be mistaken for this test's run.
  defp attach_rescan_telemetry(limit) do
    handler = "test-#{inspect(make_ref())}"
    test_pid = self()

    :telemetry.attach_many(
      handler,
      [
        TelemetryEvents.channel_post_rescanned(),
        TelemetryEvents.channel_post_rescan_failed()
      ],
      fn name, measurements, metadata, _ ->
        if metadata[:limit] == limit do
          send(test_pid, {:telemetry, List.last(name), measurements, metadata})
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  defp attach_quarantine_telemetry(tenant_id) do
    handler = "test-#{inspect(make_ref())}"
    test_pid = self()

    :telemetry.attach(
      handler,
      TelemetryEvents.channel_post_quarantined(),
      fn name, measurements, metadata, _ ->
        if metadata[:tenant_id] == tenant_id do
          send(test_pid, {:telemetry, List.last(name), measurements, metadata})
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  # There is deliberately NO channel-post fixture here: `Coordination.create_post/4`
  # REJECTS a denylisted body at write time, so it cannot build the row this worker
  # exists for. Insert the ChannelPost struct DIRECTLY via AdminRepo (bypassing the
  # changeset) to simulate a post written BEFORE the pattern existed. AdminRepo
  # (BYPASSRLS) for every read/write — the RLS repo would hide these rows.
  defp insert_post(ctx, attrs \\ %{}) do
    %ChannelPost{
      tenant_id: ctx.tenant.id,
      project_id: ctx.project.id,
      agent_id: ctx.agent.id,
      body: "ordinary coordination chatter",
      expires_at: DateTime.add(DateTime.utc_now(), 30 * 86_400, :second)
    }
    |> struct(attrs)
    |> AdminRepo.insert!()
  end

  defp setup_context do
    tenant = fixture(:tenant)
    project = fixture(:project, %{tenant_id: tenant.id})
    agent = fixture(:agent, %{tenant_id: tenant.id})
    %{tenant: tenant, project: project, agent: agent}
  end

  defp quarantine_audits(tenant_id) do
    from(a in AuditLog,
      where:
        a.tenant_id == ^tenant_id and a.entity_type == "channel_post" and
          a.action == "quarantined"
    )
    |> AdminRepo.all()
  end

  defp anomalies_for(tenant_id) do
    from(a in IngestionAnomaly, where: a.tenant_id == ^tenant_id) |> AdminRepo.all()
  end

  defp reload(post), do: AdminRepo.get(ChannelPost, post.id)

  describe "perform/1 — retroactive detection" do
    # AC-499.1: a post written BEFORE the pattern existed is DETECTED and FLAGGED —
    # and, crucially, NOT deleted.
    test "quarantines a pre-existing post carrying a denylisted shape, keeping the row" do
      ctx = setup_context()
      offender = insert_post(ctx, %{body: "here is the key #{@secret} use it"})

      assert :ok = ChannelPostRescanWorker.perform(%Oban.Job{args: %{}})

      reloaded = reload(offender)
      # The ROW SURVIVES — quarantine is never a delete (the denylist is a heuristic).
      refute is_nil(reloaded)
      assert %DateTime{} = reloaded.quarantined_at
      assert reloaded.quarantine_reason == "secret_denylist: body"
      # The reason names FIELDS only — never the matched value.
      refute reloaded.quarantine_reason =~ @secret
    end

    test "detects a denylisted shape inside a refs item field, not just the body" do
      ctx = setup_context()

      offender =
        insert_post(ctx, %{
          refs: [%{"type" => "note", "value" => @secret, "label" => "creds"}]
        })

      assert :ok = ChannelPostRescanWorker.perform(%Oban.Job{args: %{}})

      assert reload(offender).quarantine_reason == "secret_denylist: refs"
    end

    test "leaves a clean post untouched, stamping only the rescan cursor" do
      ctx = setup_context()
      clean = insert_post(ctx)

      assert :ok = ChannelPostRescanWorker.perform(%Oban.Job{args: %{}})

      reloaded = reload(clean)
      assert is_nil(reloaded.quarantined_at)
      assert is_nil(reloaded.quarantine_reason)
      assert %DateTime{} = reloaded.rescanned_at
      assert quarantine_audits(ctx.tenant.id) == []
    end

    # An expired post is already invisible to every read and the TTL sweep is about to
    # hard-delete it, so re-scanning it is wasted work.
    test "skips expired posts" do
      ctx = setup_context()

      expired =
        insert_post(ctx, %{
          body: "old #{@secret}",
          expires_at: DateTime.add(DateTime.utc_now(), -60, :second)
        })

      assert :ok = ChannelPostRescanWorker.perform(%Oban.Job{args: %{}})

      reloaded = reload(expired)
      assert is_nil(reloaded.quarantined_at)
      assert is_nil(reloaded.rescanned_at)
    end

    # AC-499.3: every detection is recorded in the append-only, hash-chained audit log.
    test "audits every detection with field names only" do
      ctx = setup_context()
      offender = insert_post(ctx, %{body: "leak #{@secret}"})

      assert :ok = ChannelPostRescanWorker.perform(%Oban.Job{args: %{}})

      assert [entry] = quarantine_audits(ctx.tenant.id)
      assert entry.entity_id == offender.id
      assert entry.actor_type == "system"
      assert entry.metadata["reason"] == "secret_denylist"
      assert entry.metadata["fields"] == ["body"]
      refute inspect(entry.metadata) =~ @secret
    end
  end

  describe "perform/1 — bounded + idempotent" do
    # AC-499.2 (bounded): with N+1 offenders and limit N, at most N are quarantined per
    # run; a second run picks up the rest (the cron drains a backlog over runs).
    test "quarantines at most `limit` posts per run and resumes on the next run" do
      ctx = setup_context()
      for _ <- 1..3, do: insert_post(ctx, %{body: "leak #{@secret}"})

      job = %Oban.Job{args: %{"limit" => 2}}

      assert :ok = ChannelPostRescanWorker.perform(job)
      assert quarantined_count(ctx.tenant.id) == 2

      assert :ok = ChannelPostRescanWorker.perform(job)
      assert quarantined_count(ctx.tenant.id) == 3
    end

    test "advances the cursor so successive bounded runs scan NEW posts" do
      ctx = setup_context()
      first = insert_post(ctx)
      second = insert_post(ctx)

      job = %Oban.Job{args: %{"limit" => 1}}

      assert :ok = ChannelPostRescanWorker.perform(job)
      assert %DateTime{} = reload(first).rescanned_at
      assert is_nil(reload(second).rescanned_at)

      assert :ok = ChannelPostRescanWorker.perform(job)
      assert %DateTime{} = reload(second).rescanned_at
    end

    # AC-499.2 (idempotent): a re-run over an already-quarantined row writes no second
    # audit entry and raises no second anomaly/alert.
    test "is idempotent: a second run neither re-audits nor re-alerts" do
      ctx = setup_context()
      insert_post(ctx, %{body: "leak #{@secret}"})

      assert :ok = ChannelPostRescanWorker.perform(%Oban.Job{args: %{}})
      assert length(quarantine_audits(ctx.tenant.id)) == 1
      assert [anomaly] = anomalies_for(ctx.tenant.id)

      assert :ok = ChannelPostRescanWorker.perform(%Oban.Job{args: %{}})

      assert length(quarantine_audits(ctx.tenant.id)) == 1
      assert [^anomaly] = anomalies_for(ctx.tenant.id)
    end
  end

  describe "perform/1 — operator surface" do
    test "records a secret_detected anomaly and enqueues the operator alert" do
      ctx = setup_context()
      insert_post(ctx, %{body: "leak #{@secret}"})

      log =
        capture_log(fn ->
          Oban.Testing.with_testing_mode(:manual, fn ->
            assert :ok = ChannelPostRescanWorker.perform(%Oban.Job{args: %{}})
            assert_enqueued(worker: ScaleAlertDeliveryWorker)
          end)
        end)

      assert log =~ "credential shape detected on the coordination bus"

      assert [anomaly] = anomalies_for(ctx.tenant.id)
      assert anomaly.anomaly_type == :secret_detected
      assert anomaly.source_type == "channel_post_rescan"
      assert anomaly.sample_count == 1
      assert anomaly.hours_stale == 0
      assert anomaly.resolved == false
      # `alerted` flips only AFTER the enqueue succeeds (at-least-once).
      assert anomaly.alerted == true
      assert anomaly.metadata["fields"] == ["body"]
      refute inspect(anomaly.metadata) =~ @secret
    end

    # At-least-once recovery: a crash between the atomic anomaly insert and the
    # post-commit enqueue leaves alerted: false, and the next run must re-fire rather
    # than take the silent refresh path forever.
    test "re-fires the operator alert when a previous run left alerted: false" do
      ctx = setup_context()
      insert_post(ctx, %{body: "leak #{@secret}"})

      assert :ok = ChannelPostRescanWorker.perform(%Oban.Job{args: %{}})
      [anomaly] = anomalies_for(ctx.tenant.id)

      anomaly
      |> Ecto.Changeset.change(alerted: false)
      |> AdminRepo.update!()

      # A NEW offender in the same tenant while the anomaly is open.
      insert_post(ctx, %{body: "another #{@secret}"})

      Oban.Testing.with_testing_mode(:manual, fn ->
        assert :ok = ChannelPostRescanWorker.perform(%Oban.Job{args: %{}})
        assert_enqueued(worker: ScaleAlertDeliveryWorker)
      end)

      [refreshed] = anomalies_for(ctx.tenant.id)
      assert refreshed.alerted == true
      # Figures ACCUMULATE while the anomaly stays open.
      assert refreshed.sample_count == 2
    end

    test "an ARCHIVED anomaly suppresses the alert but never the quarantine + audit" do
      ctx = setup_context()
      insert_post(ctx, %{body: "leak #{@secret}"})

      assert :ok = ChannelPostRescanWorker.perform(%Oban.Job{args: %{}})
      [anomaly] = anomalies_for(ctx.tenant.id)

      anomaly
      |> Ecto.Changeset.change(archived: true, resolved: true)
      |> AdminRepo.update!()

      offender = insert_post(ctx, %{body: "another #{@secret}"})

      assert :ok = ChannelPostRescanWorker.perform(%Oban.Job{args: %{}})

      # Still quarantined + audited — only the paging is suppressed.
      assert %DateTime{} = reload(offender).quarantined_at
      assert length(quarantine_audits(ctx.tenant.id)) == 2
      # No SECOND anomaly, and the archived one keeps its pre-suppression figures.
      assert [suppressed] = anomalies_for(ctx.tenant.id)
      assert suppressed.id == anomaly.id
      assert suppressed.sample_count == 1
    end

    test "emits per-hit quarantine telemetry with field names only" do
      ctx = setup_context()
      attach_quarantine_telemetry(ctx.tenant.id)
      insert_post(ctx, %{body: "leak #{@secret}"})

      assert :ok = ChannelPostRescanWorker.perform(%Oban.Job{args: %{}})

      assert_receive {:telemetry, :channel_post_quarantined, %{count: 1}, metadata}
      assert metadata.fields == "body"
      assert metadata.project_id == ctx.project.id
      refute inspect(metadata) =~ @secret
    end
  end

  describe "perform/1 — read exclusion" do
    # The whole point: a flagged post that is STILL injected into every session buys
    # nothing. It must leave every read surface.
    test "a quarantined post disappears from recent/3, get_post/2 and directed handoffs" do
      ctx = setup_context()

      offender =
        insert_post(ctx, %{
          key: "handoff:repo#499",
          session_id: "sess-499",
          body: "leak #{@secret}"
        })

      assert {:ok, _} = Coordination.get_post(ctx.tenant.id, offender.id)

      assert :ok = ChannelPostRescanWorker.perform(%Oban.Job{args: %{}})

      assert {:error, :not_found} = Coordination.get_post(ctx.tenant.id, offender.id)
      assert Coordination.recent(ctx.tenant.id, ctx.project.id) == []
      assert Coordination.directed_handoffs(ctx.tenant.id, ctx.project.id, %{}) == []
    end
  end

  describe "perform/1 — tenant isolation" do
    test "tenant A's rescan never quarantines or exposes tenant B's rows" do
      ctx_a = setup_context()
      ctx_b = setup_context()

      refute ctx_a.tenant.id == ctx_b.tenant.id

      offender_a = insert_post(ctx_a, %{body: "leak #{@secret}"})
      clean_b = insert_post(ctx_b)

      assert :ok = ChannelPostRescanWorker.perform(%Oban.Job{args: %{}})

      assert %DateTime{} = reload(offender_a).quarantined_at
      assert is_nil(reload(clean_b).quarantined_at)

      # The anomaly + audit land under the OFFENDING tenant only.
      assert [_] = anomalies_for(ctx_a.tenant.id)
      assert anomalies_for(ctx_b.tenant.id) == []
      assert quarantine_audits(ctx_b.tenant.id) == []
    end

    test "each offending tenant gets its OWN anomaly in a cross-tenant run" do
      ctx_a = setup_context()
      ctx_b = setup_context()

      insert_post(ctx_a, %{body: "leak #{@secret}"})
      insert_post(ctx_b, %{body: "leak #{@secret}"})

      assert :ok = ChannelPostRescanWorker.perform(%Oban.Job{args: %{}})

      assert [%{anomaly_type: :secret_detected}] = anomalies_for(ctx_a.tenant.id)
      assert [%{anomaly_type: :secret_detected}] = anomalies_for(ctx_b.tenant.id)
    end
  end

  describe "perform/1 — rescan telemetry" do
    test "emits success telemetry carrying the scanned and quarantined counts" do
      ctx = setup_context()
      attach_rescan_telemetry(23)

      insert_post(ctx, %{body: "leak #{@secret}"})
      insert_post(ctx)

      assert :ok = ChannelPostRescanWorker.perform(%Oban.Job{args: %{"limit" => 23}})

      assert_receive {:telemetry, :channel_post_rescanned, %{scanned: 2, quarantined: 1},
                      %{limit: 23}}
    end

    # The load-bearing half: a run with nothing due must STILL emit, or "nothing to do"
    # is indistinguishable from "never ran".
    test "emits success telemetry with zero counts on a no-op run" do
      attach_rescan_telemetry(29)

      assert :ok = ChannelPostRescanWorker.perform(%Oban.Job{args: %{"limit" => 29}})

      assert_receive {:telemetry, :channel_post_rescanned, %{scanned: 0, quarantined: 0},
                      %{limit: 29}}
    end

    test "logs at error, emits failure telemetry, and re-raises on a DB failure" do
      attach_rescan_telemetry(31)

      # Break the candidate read at the DB with NO global locks and no schema damage:
      # a SESSION-LOCAL temp table shadows `channel_posts` on this connection only
      # (pg_temp is searched before public) and lacks `expires_at`. It lives inside the
      # sandbox transaction, so no concurrent async test can see it.
      AdminRepo.query!("CREATE TEMP TABLE channel_posts (id uuid)")

      log =
        capture_log(fn ->
          assert_raise Postgrex.Error, fn ->
            ChannelPostRescanWorker.perform(%Oban.Job{args: %{"limit" => 31}})
          end
        end)

      assert log =~ "ChannelPostRescanWorker failed to rescan channel posts"
      assert log =~ "error_class=Postgrex.Error"

      assert_receive {:telemetry, :channel_post_rescan_failed, %{count: 1},
                      %{limit: 31, error_class: "Postgrex.Error"}}

      refute_receive {:telemetry, :channel_post_rescanned, _, _}, 50
    end

    # `rescue` observes EXCEPTIONS only. A pool checkout failure / ownership loss
    # surfaces as an `exit` and would otherwise bypass the whole contract. Driven
    # through `observed/2` — the exact function `perform/1` runs its rescan under.
    test "logs at error, emits failure telemetry, and re-EXITS on a non-exception exit" do
      attach_rescan_telemetry(37)

      log =
        capture_log(fn ->
          assert catch_exit(ChannelPostRescanWorker.observed(37, fn -> exit(:pool_dead) end)) ==
                   :pool_dead
        end)

      assert log =~ "ChannelPostRescanWorker failed to rescan channel posts"
      assert log =~ "error_class=exit"

      assert_receive {:telemetry, :channel_post_rescan_failed, %{count: 1},
                      %{limit: 37, error_class: "exit"}}

      refute_receive {:telemetry, :channel_post_rescanned, _, _}, 50
    end
  end

  defp quarantined_count(tenant_id) do
    from(p in ChannelPost,
      where: p.tenant_id == ^tenant_id and not is_nil(p.quarantined_at)
    )
    |> AdminRepo.aggregate(:count)
  end
end
