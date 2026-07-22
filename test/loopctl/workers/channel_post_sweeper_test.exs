defmodule Loopctl.Workers.ChannelPostSweeperTest do
  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  import ExUnit.CaptureLog

  alias Loopctl.AdminRepo
  alias Loopctl.Coordination.ChannelPost
  alias Loopctl.TelemetryEvents
  alias Loopctl.Workers.ChannelPostSweeper

  # Telemetry handlers are GLOBAL and async tests run concurrently, so every assertion
  # below filters on a per-test-unique `limit` (carried in the event metadata) — a
  # concurrent emitter of the same event can never be mistaken for this test's run.
  defp attach_sweep_telemetry(limit) do
    handler = "test-#{inspect(make_ref())}"
    test_pid = self()

    :telemetry.attach_many(
      handler,
      [
        TelemetryEvents.channel_post_swept(),
        TelemetryEvents.channel_post_sweep_failed()
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

  # There is no channel_post fixture: create_post/4 always stamps expires_at at
  # now + 30d, so it cannot build an already-expired row. Insert ChannelPost
  # structs directly via AdminRepo (all fields set programmatically, never via
  # changeset) so we control expires_at. Use AdminRepo (BYPASSRLS) for every
  # read/write — the RLS repo would hide/deny these rows.
  defp insert_post(tenant, project, agent, offset_seconds) do
    %ChannelPost{
      tenant_id: tenant.id,
      project_id: project.id,
      agent_id: agent.id,
      body: "post",
      expires_at: DateTime.add(DateTime.utc_now(), offset_seconds, :second)
    }
    |> AdminRepo.insert!()
  end

  defp setup_context do
    tenant = fixture(:tenant)
    project = fixture(:project, %{tenant_id: tenant.id})
    agent = fixture(:agent, %{tenant_id: tenant.id})
    %{tenant: tenant, project: project, agent: agent}
  end

  describe "perform/1" do
    # TC-39.5.1
    test "deletes channel posts past expires_at and leaves live ones" do
      %{tenant: tenant, project: project, agent: agent} = setup_context()

      expired = insert_post(tenant, project, agent, -60)
      live = insert_post(tenant, project, agent, 3600)

      assert :ok = ChannelPostSweeper.perform(%Oban.Job{args: %{}})

      assert is_nil(AdminRepo.get(ChannelPost, expired.id))
      refute is_nil(AdminRepo.get(ChannelPost, live.id))
    end

    # TC-39.5.2
    test "is idempotent: no expired rows means a zero-delete no-op on repeated runs" do
      %{tenant: tenant, project: project, agent: agent} = setup_context()

      live = insert_post(tenant, project, agent, 3600)

      assert :ok = ChannelPostSweeper.perform(%Oban.Job{args: %{}})
      assert :ok = ChannelPostSweeper.perform(%Oban.Job{args: %{}})

      refute is_nil(AdminRepo.get(ChannelPost, live.id))
    end

    # TC-39.5.3
    test "honors the per-run batch bound: at most limit deleted per run, rest swept next run" do
      %{tenant: tenant, project: project, agent: agent} = setup_context()

      # Three expired rows, a batch limit of 2: first run deletes 2, one remains,
      # second run deletes the last.
      for _ <- 1..3, do: insert_post(tenant, project, agent, -60)

      job = %Oban.Job{args: %{"limit" => 2}}

      assert :ok = ChannelPostSweeper.perform(job)
      assert AdminRepo.aggregate(expired_query(), :count) == 1

      assert :ok = ChannelPostSweeper.perform(job)
      assert AdminRepo.aggregate(expired_query(), :count) == 0
    end

    # TC-39.5.5 — an operator-supplied "limit" over Postgres's 65535 bind-parameter
    # cap must NOT crash the job. The selected ids are passed as an explicit list to
    # `where(p.id in ^batch_ids)` (one bind param each), so batch_limit/1 clamps the
    # arg to @batch_size. Passing a value well above the cap still sweeps normally.
    test "clamps an oversized limit arg so it never exceeds the bind-parameter cap" do
      %{tenant: tenant, project: project, agent: agent} = setup_context()

      for _ <- 1..3, do: insert_post(tenant, project, agent, -60)

      assert :ok = ChannelPostSweeper.perform(%Oban.Job{args: %{"limit" => 70_000}})
      assert AdminRepo.aggregate(expired_query(), :count) == 0
    end

    # TC-39.5.4 — AC-39.5.3: the BYPASSRLS sweep is cross-tenant. The predicate
    # (`expires_at < now()`) carries no tenant column, so a SINGLE perform/1 run
    # must delete an expired row under tenant A while leaving a live row under a
    # DIFFERENT tenant B untouched. This exercises the "across ALL tenants" half
    # of the AC that the single-tenant cases above only assert implicitly.
    test "sweeps expired rows across all tenants in one run, leaving live rows in other tenants" do
      %{tenant: tenant_a, project: project_a, agent: agent_a} = setup_context()
      %{tenant: tenant_b, project: project_b, agent: agent_b} = setup_context()

      assert tenant_a.id != tenant_b.id

      expired_a = insert_post(tenant_a, project_a, agent_a, -60)
      live_b = insert_post(tenant_b, project_b, agent_b, 3600)

      assert :ok = ChannelPostSweeper.perform(%Oban.Job{args: %{}})

      assert is_nil(AdminRepo.get(ChannelPost, expired_a.id))
      refute is_nil(AdminRepo.get(ChannelPost, live_b.id))
    end
  end

  # AC-39.5.5 / issue #498 — a sweep must be observable on BOTH outcomes.
  describe "perform/1 — sweep telemetry (TC-39.5.6/7/8)" do
    # TC-39.5.6
    test "emits sweep-success telemetry carrying the deleted count" do
      %{tenant: tenant, project: project, agent: agent} = setup_context()
      attach_sweep_telemetry(7)

      for _ <- 1..2, do: insert_post(tenant, project, agent, -60)

      assert :ok = ChannelPostSweeper.perform(%Oban.Job{args: %{"limit" => 7}})

      assert_receive {:telemetry, :channel_post_swept, %{deleted: 2}, %{limit: 7}}
    end

    # TC-39.5.7 — the load-bearing half of "success telemetry": a run that deletes
    # NOTHING must still emit, or "nothing to do" is indistinguishable from "never ran".
    test "emits sweep-success telemetry with deleted: 0 on a no-op run" do
      %{tenant: tenant, project: project, agent: agent} = setup_context()
      attach_sweep_telemetry(11)

      insert_post(tenant, project, agent, 3600)

      assert :ok = ChannelPostSweeper.perform(%Oban.Job{args: %{"limit" => 11}})

      assert_receive {:telemetry, :channel_post_swept, %{deleted: 0}, %{limit: 11}}
    end

    # TC-39.5.8 — a DB failure must produce an error log AND failure telemetry AND
    # still RAISE, so Oban records the failure and retries (max_attempts: 3). A rescue
    # that returned :ok would hide a permanently dead retention sweep.
    test "logs at error, emits failure telemetry, and re-raises on a DB failure" do
      attach_sweep_telemetry(13)

      # Break the sweep's read at the DB with NO global locks and no schema damage:
      # a SESSION-LOCAL temp table shadows `channel_posts` on this connection only
      # (pg_temp is searched before public), and it lacks `expires_at`, so the sweep's
      # first statement raises Postgrex.Error. It is created inside the sandbox
      # transaction, so it vanishes on rollback and no concurrent async test can see it.
      AdminRepo.query!("CREATE TEMP TABLE channel_posts (id uuid)")

      log =
        capture_log(fn ->
          assert_raise Postgrex.Error, fn ->
            ChannelPostSweeper.perform(%Oban.Job{args: %{"limit" => 13}})
          end
        end)

      assert log =~ "ChannelPostSweeper failed to sweep expired channel posts"
      assert log =~ "error_class=Postgrex.Error"

      assert_receive {:telemetry, :channel_post_sweep_failed, %{count: 1},
                      %{limit: 13, error_class: "Postgrex.Error"}}

      refute_receive {:telemetry, :channel_post_swept, _, _}, 50
    end

    # TC-39.5.14 — `rescue` observes EXCEPTIONS only. A DBConnection ownership/connection
    # loss or a pool checkout failure surfacing as an `exit` would otherwise bypass the
    # whole contract above and be visible only as Oban retry churn — the assumed-healthy
    # failure #498 exists to close. Driven through `observed/2`, the exact function
    # `perform/1` runs its sweep under (a genuine pool exit is not reproducible under the
    # Ecto sandbox, and a repo double would test the double, not this contract).
    test "logs at error, emits failure telemetry, and re-EXITS on a non-exception exit" do
      attach_sweep_telemetry(17)

      log =
        capture_log(fn ->
          assert catch_exit(ChannelPostSweeper.observed(17, fn -> exit(:pool_dead) end)) ==
                   :pool_dead
        end)

      assert log =~ "ChannelPostSweeper failed to sweep expired channel posts"
      assert log =~ "error_class=exit"

      assert_receive {:telemetry, :channel_post_sweep_failed, %{count: 1},
                      %{limit: 17, error_class: "exit"}}

      refute_receive {:telemetry, :channel_post_swept, _, _}, 50
    end
  end

  defp expired_query do
    import Ecto.Query
    now = DateTime.utc_now()
    from(p in ChannelPost, where: p.expires_at < ^now)
  end
end
