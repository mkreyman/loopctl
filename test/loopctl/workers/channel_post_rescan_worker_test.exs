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
  alias Loopctl.Security.SecretDenylist
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

  # An instant `seconds` away from the declared denylist revision, at the microsecond
  # precision `rescanned_at` (`:utc_datetime_usec`) requires.
  defp revision_offset(seconds) do
    SecretDenylist.revision()
    |> DateTime.add(seconds, :second)
    |> then(&%{&1 | microsecond: {0, 6}})
  end

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
      # `updated_at` is the DELTA-READ watermark (recent_page/3 filters AND orders
      # `?since=` on GREATEST(inserted_at, updated_at)). A clean rescan must NOT touch
      # it, or every run re-broadcasts the whole live channel to every ?since= consumer
      # — the amplification #499 exists to shrink.
      assert reloaded.updated_at == clean.updated_at
      assert quarantine_audits(ctx.tenant.id) == []
    end

    # The behavioural half of the assertion above: after a rescan, a delta consumer whose
    # cursor predates the run must see NOTHING new.
    test "a rescanned clean post does not re-surface in a ?since= delta read" do
      ctx = setup_context()

      # An OLD post, comfortably outside the delta read's commit-lag look-back.
      old = DateTime.add(DateTime.utc_now(), -3600, :second)
      insert_post(ctx, %{inserted_at: old, updated_at: old})

      # A consumer that has already read everything up to now.
      since = DateTime.utc_now()

      assert :ok = ChannelPostRescanWorker.perform(%Oban.Job{args: %{}})

      assert {[], false, _cursor} =
               Coordination.recent_page(ctx.tenant.id, ctx.project.id, since: since)
    end

    # AC-499.1's headline: RETROACTIVITY. A post already scanned under an OLDER pattern
    # set (rescanned_at < SecretDenylist.revision/0) is re-examined and caught.
    test "re-examines a post scanned BEFORE the current denylist revision" do
      ctx = setup_context()
      before_revision = revision_offset(-3600)

      stale =
        insert_post(ctx, %{body: "written earlier #{@secret}", rescanned_at: before_revision})

      assert :ok = ChannelPostRescanWorker.perform(%Oban.Job{args: %{}})

      reloaded = reload(stale)
      assert %DateTime{} = reloaded.quarantined_at
      assert reloaded.quarantine_reason == "secret_denylist: body"
    end

    # The bound that stops the worker re-walking the whole corpus every hour: a post
    # already scanned UNDER the current revision is skipped, even if it would match.
    test "skips a post already scanned at or after the current denylist revision" do
      ctx = setup_context()
      after_revision = revision_offset(3600)

      scanned =
        insert_post(ctx, %{body: "already vetted #{@secret}", rescanned_at: after_revision})

      assert :ok = ChannelPostRescanWorker.perform(%Oban.Job{args: %{}})

      reloaded = reload(scanned)
      assert is_nil(reloaded.quarantined_at)
      assert reloaded.rescanned_at == after_revision
    end

    # Quarantine must not let the TTL sweeper delete the operator's only reviewable
    # artifact while the (never auto-resolved) anomaly is still open.
    test "extends expires_at to the operator review window when quarantining" do
      ctx = setup_context()

      offender =
        insert_post(ctx, %{
          body: "leak #{@secret}",
          # About to be swept: one day of TTL left.
          expires_at: DateTime.add(DateTime.utc_now(), 86_400, :second)
        })

      assert :ok = ChannelPostRescanWorker.perform(%Oban.Job{args: %{}})

      reloaded = reload(offender)
      review_floor = DateTime.add(DateTime.utc_now(), 29 * 86_400, :second)
      assert DateTime.compare(reloaded.expires_at, review_floor) == :gt
    end

    test "never SHORTENS the TTL of a post that already outlives the review window" do
      ctx = setup_context()
      far_future = DateTime.add(DateTime.utc_now(), 120 * 86_400, :second)

      offender = insert_post(ctx, %{body: "leak #{@secret}", expires_at: far_future})

      assert :ok = ChannelPostRescanWorker.perform(%Oban.Job{args: %{}})

      assert DateTime.compare(reload(offender).expires_at, far_future) == :eq
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

    # A leaked credential is a DISCRETE, individually-actionable security event — unlike
    # the #498 episode detectors, where an open anomaly means the ONE ongoing condition
    # is already paged. Credentials 2..N must page too, or "#499 detections are surfaced
    # to the operator" holds only for the first one.
    test "re-alerts on a LATER distinct detection while the anomaly is still open" do
      ctx = setup_context()
      insert_post(ctx, %{body: "leak #{@secret}"})

      Oban.Testing.with_testing_mode(:manual, fn ->
        assert :ok = ChannelPostRescanWorker.perform(%Oban.Job{args: %{}})
        assert_enqueued(worker: ScaleAlertDeliveryWorker)

        [anomaly] = anomalies_for(ctx.tenant.id)
        assert anomaly.alerted == true

        # A SECOND, distinct leak lands while the first anomaly is unresolved.
        insert_post(ctx, %{body: "another #{@secret}"})
        assert :ok = ChannelPostRescanWorker.perform(%Oban.Job{args: %{}})

        # TWO pages, not one — and the figures accumulated.
        assert length(all_enqueued(worker: ScaleAlertDeliveryWorker)) == 2
        assert [%{sample_count: 2}] = anomalies_for(ctx.tenant.id)
      end)
    end

    # The operator's `post_ids` sample is their only direct pointer to the rows to
    # review or redact. A backlog drained across successive bounded runs must not leave
    # them holding the LAST batch only.
    test "accumulates post_ids across runs instead of replacing them" do
      ctx = setup_context()
      first = insert_post(ctx, %{body: "leak #{@secret}"})
      second = insert_post(ctx, %{body: "another #{@secret}"})

      job = %Oban.Job{args: %{"limit" => 1}}
      assert :ok = ChannelPostRescanWorker.perform(job)
      assert :ok = ChannelPostRescanWorker.perform(job)

      assert [anomaly] = anomalies_for(ctx.tenant.id)
      assert anomaly.sample_count == 2
      assert Enum.sort(anomaly.metadata["post_ids"]) == Enum.sort([first.id, second.id])
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

  describe "perform/1 — version-skew probes" do
    # The catalog probes decide whether the whole security rescan runs. `conname` is
    # unique per SCHEMA (and information_schema.columns is database-wide), so a
    # NAMESAKE object — a staging schema, a pg_dump restored alongside — must not make
    # the probe fall through to "migration pending" and disable the rescan forever.
    test "still runs when a namesake channel_posts exists in another schema" do
      ctx = setup_context()
      schema = "skew_#{System.unique_integer([:positive])}"
      AdminRepo.query!("CREATE SCHEMA #{schema}")
      AdminRepo.query!("CREATE TABLE #{schema}.channel_posts (quarantined_at timestamptz)")

      offender = insert_post(ctx, %{body: "leak #{@secret}"})

      assert :ok = ChannelPostRescanWorker.perform(%Oban.Job{args: %{}})

      assert %DateTime{} = reload(offender).quarantined_at
    end

    # The other half: a crontab deploy that lands AHEAD of the migrations must skip
    # quietly (and self-heal next run) rather than burn Oban retries.
    test "skips quietly, warning, when the quarantine migration is not visible" do
      ctx = setup_context()
      offender = insert_post(ctx, %{body: "leak #{@secret}"})
      schema = "skew_#{System.unique_integer([:positive])}"
      AdminRepo.query!("CREATE SCHEMA #{schema}")

      log =
        capture_log(fn ->
          # An empty search_path stands in for "the migrations have not landed yet".
          AdminRepo.query!("SET LOCAL search_path TO #{schema}")

          try do
            assert :ok = ChannelPostRescanWorker.perform(%Oban.Job{args: %{}})
          after
            AdminRepo.query!(~s|SET LOCAL search_path TO "$user", public|)
          end
        end)

      assert log =~ "migration pending"
      assert is_nil(reload(offender).quarantined_at)
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
