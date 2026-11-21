defmodule Loopctl.CoordinationSoftLockTest do
  @moduledoc """
  US-40.4 / US-52.21 — ADVISORY file soft-locks (`Coordination.lock_file/5`,
  `unlock_file/5`, `active_locks/3`), stored in `channel_locks`.

  These are NOT the exactly-once handoff claim (`claim/5` + `channel_claims`,
  covered by `coordination_claim_test.exs`). A soft-lock is advisory: it never
  blocks a caller and two sessions may hold one on the same file.
  """
  use Loopctl.DataCase, async: true

  import Ecto.Query

  setup :verify_on_exit!

  alias Loopctl.AdminRepo
  alias Loopctl.Audit.AuditLog
  alias Loopctl.Coordination
  alias Loopctl.Coordination.ChannelLock
  alias Loopctl.Coordination.ChannelPost
  alias Loopctl.Workers.ChannelPostSweeper

  @target "lib/foo.ex"

  # Make an agent a writable member of a project (the shared US-40.D3 gate).
  defp make_member(tenant, project, agent_id) do
    fixture(:story, %{
      tenant_id: tenant.id,
      project_id: project.id,
      assigned_agent_id: agent_id,
      agent_status: :assigned
    })
  end

  defp audit(label \\ "agent:worker-1") do
    [actor_type: "api_key", actor_id: Ecto.UUID.generate(), actor_label: label]
  end

  defp setup_member do
    tenant = fixture(:tenant)
    project = fixture(:project, %{tenant_id: tenant.id})
    agent_id = fixture(:agent, %{tenant_id: tenant.id}).id
    make_member(tenant, project, agent_id)
    %{tenant: tenant, project: project, agent_id: agent_id}
  end

  defp take_lock(ctx, opts \\ []) do
    opts =
      opts
      |> Keyword.put_new(:session_id, "sess-a")
      |> Keyword.put_new(:role, :agent)
      |> Keyword.put_new(:audit, audit())

    Coordination.lock_file(
      ctx.tenant.id,
      Keyword.get(opts, :agent_id, ctx.agent_id),
      Keyword.get(opts, :project_id, ctx.project.id),
      Keyword.get(opts, :target, @target),
      Keyword.drop(opts, [:agent_id, :project_id, :target])
    )
  end

  defp lock_rows(tenant_id, project_id) do
    AdminRepo.all(
      from(l in ChannelLock,
        where: l.tenant_id == ^tenant_id and l.project_id == ^project_id,
        order_by: [asc: l.inserted_at]
      )
    )
  end

  defp post_count(tenant_id, project_id) do
    AdminRepo.aggregate(
      from(p in ChannelPost, where: p.tenant_id == ^tenant_id and p.project_id == ^project_id),
      :count
    )
  end

  defp audit_actions(tenant_id, entity_id) do
    AdminRepo.all(
      from(a in AuditLog,
        where: a.tenant_id == ^tenant_id and a.entity_type == "channel_lock",
        where: a.entity_id == ^entity_id,
        order_by: [asc: a.inserted_at],
        select: a.action
      )
    )
  end

  defp unlock(ctx, session_id, opts \\ []) do
    Coordination.unlock_file(
      ctx.tenant.id,
      Keyword.get(opts, :agent_id, ctx.agent_id),
      ctx.project.id,
      Keyword.get(opts, :target, @target),
      session_id: session_id,
      audit: audit()
    )
  end

  describe "lock_file/5 writes channel_locks, never channel_posts (TC-52.21.1)" do
    test "a lock and its refresh are one channel_locks row with a clamped TTL and no post" do
      ctx = setup_member()

      assert {:ok, %ChannelLock{} = first, :created} =
               take_lock(ctx, target: "./lib/foo.ex", session_id: "s1", ttl_seconds: 99_999)

      assert {:ok, %ChannelLock{} = second, :updated} =
               take_lock(ctx, target: "./lib/foo.ex", session_id: "s1", ttl_seconds: 99_999)

      assert second.id == first.id
      assert [row] = lock_rows(ctx.tenant.id, ctx.project.id)
      assert row.target == "lib/foo.ex"
      assert row.session_id == "s1"
      assert row.agent_id == ctx.agent_id

      ceiling = DateTime.add(DateTime.utc_now(), 3600, :second)
      assert DateTime.compare(row.expires_at, ceiling) != :gt
      assert post_count(ctx.tenant.id, ctx.project.id) == 0
    end

    test "the wire shape helpers keep the pre-52.21 key, refs and default body" do
      ctx = setup_member()
      assert {:ok, lock, :created} = take_lock(ctx)

      assert ChannelLock.key(lock) == "claim:#{@target}"
      assert ChannelLock.refs(lock) == [%{"type" => "file", "value" => @target}]
      assert ChannelLock.body(lock) =~ "advisory soft-lock: editing #{@target}"

      assert {:ok, noted, :updated} = take_lock(ctx, body: "  refactoring the parser  ")
      assert noted.note == "refactoring the parser"
      assert ChannelLock.body(noted) == "refactoring the parser"
    end

    test "a blank / oversized / non-binary target is rejected with :invalid_target" do
      ctx = setup_member()

      assert {:error, :invalid_target} = take_lock(ctx, target: "   ")
      assert {:error, :invalid_target} = take_lock(ctx, target: "")
      assert {:error, :invalid_target} = take_lock(ctx, target: nil)
      assert {:error, :invalid_target} = take_lock(ctx, target: 42)
      assert {:error, :invalid_target} = take_lock(ctx, target: String.duplicate("a", 195))

      # 194 bytes keeps the wire key ("claim:" <> target) within 200 bytes.
      assert {:ok, _lock, :created} = take_lock(ctx, target: String.duplicate("a", 194))
    end

    test "a lock write with no session_id is REJECTED and writes nothing" do
      ctx = setup_member()

      assert {:error, :missing_session} = take_lock(ctx, session_id: nil)
      assert {:error, :missing_session} = take_lock(ctx, session_id: "   ")
      assert lock_rows(ctx.tenant.id, ctx.project.id) == []
    end
  end

  describe "the write gates (TC-52.21.2)" do
    test "a credential-shaped note is refused with a note error and the secret signal" do
      ctx = setup_member()
      test_pid = self()
      handler = "soft-lock-secret-#{inspect(make_ref())}"

      :telemetry.attach(
        handler,
        [:loopctl, :coordination, :secret_blocked],
        fn _name, measurements, meta, _ ->
          if meta.project_id == ctx.project.id,
            do: send(test_pid, {:secret_blocked, measurements, meta})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      assert {:error, %Ecto.Changeset{} = changeset} =
               take_lock(ctx, body: "token lc_live_0123456789abcdef")

      assert %{note: [_ | _]} = errors_on(changeset)
      assert_receive {:secret_blocked, %{count: 1}, %{field: :note}}
      assert lock_rows(ctx.tenant.id, ctx.project.id) == []
    end

    test "a credential in the session id, host or target is refused too" do
      ctx = setup_member()
      secret = "lc_live_0123456789abcdef"

      assert {:error, %Ecto.Changeset{} = cs} = take_lock(ctx, session_id: secret)
      assert %{session_id: [_ | _]} = errors_on(cs)

      assert {:error, %Ecto.Changeset{} = cs} = take_lock(ctx, host: secret)
      assert %{host: [_ | _]} = errors_on(cs)

      assert {:error, %Ecto.Changeset{} = cs} = take_lock(ctx, target: "lib/#{secret}.ex")
      assert %{target: [_ | _]} = errors_on(cs)

      assert {:error, %Ecto.Changeset{} = cs} = take_lock(ctx, body: "nul \u0000 byte")
      assert %{note: ["must not contain NUL bytes"]} = errors_on(cs)

      assert lock_rows(ctx.tenant.id, ctx.project.id) == []
    end

    test "a non-member :agent gets the byte-identical :not_found; a foreign agent :agent_not_found" do
      ctx = setup_member()
      outsider = fixture(:agent, %{tenant_id: ctx.tenant.id}).id
      sibling = fixture(:project, %{tenant_id: ctx.tenant.id})
      other = setup_member()

      assert {:error, :not_found} = take_lock(ctx, agent_id: outsider)
      assert {:error, :not_found} = take_lock(ctx, project_id: sibling.id)
      assert {:error, :not_found} = take_lock(ctx, project_id: Ecto.UUID.generate())
      assert {:error, :not_found} = take_lock(ctx, project_id: other.project.id)
      assert {:error, :not_found} = take_lock(ctx, project_id: "not-a-uuid\r\nforged")
      assert {:error, :agent_not_found} = take_lock(ctx, agent_id: other.agent_id)
      assert lock_rows(ctx.tenant.id, ctx.project.id) == []
    end

    test "a role >= :user bypasses the membership gate" do
      ctx = setup_member()
      sibling = fixture(:project, %{tenant_id: ctx.tenant.id})

      assert {:ok, _lock, :created} = take_lock(ctx, project_id: sibling.id, role: :user)
    end
  end

  describe "TTL clamping" do
    test "the clamp bounds are exact: [60, 3600] seconds, default 900" do
      assert Coordination.lock_ttl_seconds(1) == 60
      assert Coordination.lock_ttl_seconds(60) == 60
      assert Coordination.lock_ttl_seconds(3600) == 3600
      assert Coordination.lock_ttl_seconds(3601) == 3600
      assert Coordination.lock_ttl_seconds(0) == 60
      assert Coordination.lock_ttl_seconds(-5) == 60
      assert Coordination.lock_ttl_seconds(nil) == 900
      assert Coordination.lock_ttl_seconds("not-a-number") == 900
      assert Coordination.lock_ttl_seconds("12abc") == 900
      assert Coordination.lock_ttl_seconds(%{}) == 900
      assert Coordination.lock_ttl_seconds("120") == 120
      assert Coordination.lock_ttl_seconds("10") == 60
      assert Coordination.lock_ttl_seconds("99999") == 3600
      assert Coordination.max_lock_ttl_seconds() == 3600
    end

    test "a below-min, above-max, absent, and non-integer ttl all land on the clamped bound" do
      ctx = setup_member()
      before = DateTime.utc_now()

      assert {:ok, low, _} = take_lock(ctx, target: "a.ex", ttl_seconds: 5)
      assert {:ok, high, _} = take_lock(ctx, target: "b.ex", ttl_seconds: 999_999)
      assert {:ok, absent, _} = take_lock(ctx, target: "c.ex")
      assert {:ok, junk, _} = take_lock(ctx, target: "d.ex", ttl_seconds: "nonsense")

      assert_in_delta DateTime.diff(low.expires_at, before), 60, 5
      assert_in_delta DateTime.diff(high.expires_at, before), 3600, 5
      assert_in_delta DateTime.diff(absent.expires_at, before), 900, 5
      assert_in_delta DateTime.diff(junk.expires_at, before), 900, 5
    end

    test "a refresh extends the lease and keeps host and inserted_at" do
      ctx = setup_member()

      assert {:ok, first, :created} = take_lock(ctx, ttl_seconds: 60, host: "beelink")
      assert {:ok, second, :updated} = take_lock(ctx, ttl_seconds: 3600, host: "minis")

      assert second.id == first.id
      assert DateTime.compare(second.expires_at, first.expires_at) == :gt
      assert second.host == "beelink"
      assert second.inserted_at == first.inserted_at
    end
  end

  describe "advisory: never blocks — TC-40.4.4" do
    test "two sessions of the same agent hold a lock on the SAME file; both succeed and surface" do
      ctx = setup_member()

      assert {:ok, a, :created} = take_lock(ctx, session_id: "sess-a")
      assert {:ok, b, :created} = take_lock(ctx, session_id: "sess-b")

      refute a.id == b.id
      ids = ctx.tenant.id |> Coordination.active_locks(ctx.project.id) |> Enum.map(& &1.id)
      assert Enum.sort(ids) == Enum.sort([a.id, b.id])
    end

    test "two DIFFERENT agents lock the same file; neither is rejected and both surface" do
      ctx = setup_member()
      agent_b = fixture(:agent, %{tenant_id: ctx.tenant.id}).id
      make_member(ctx.tenant, ctx.project, agent_b)

      assert {:ok, _a, :created} = take_lock(ctx, session_id: "sess-a")
      assert {:ok, _b, :created} = take_lock(ctx, agent_id: agent_b, session_id: "sess-b")

      locks = Coordination.active_locks(ctx.tenant.id, ctx.project.id)
      assert length(locks) == 2
      assert Enum.all?(locks, &(&1.target == @target))
    end
  end

  describe "unlock_file/5 deletes only the caller's slot (TC-52.21.3)" do
    test "the (agent, s1) slot goes, (agent, s2) and (agent2, s1) stay, every miss is :not_found" do
      ctx = setup_member()
      agent2 = fixture(:agent, %{tenant_id: ctx.tenant.id}).id
      make_member(ctx.tenant, ctx.project, agent2)

      assert {:ok, mine, :created} = take_lock(ctx, session_id: "s1")
      assert {:ok, peer_session, :created} = take_lock(ctx, session_id: "s2")
      assert {:ok, peer_agent, :created} = take_lock(ctx, agent_id: agent2, session_id: "s1")

      assert {:ok, released} = unlock(ctx, "s1")
      assert released.id == mine.id

      missing = unlock(ctx, "s3")
      malformed = unlock(ctx, "s1", target: "")
      assert missing == {:error, :not_found}
      assert malformed == missing
      # Already released, another agent's slot under a session it never used, and a
      # missing session id: the same answer.
      assert unlock(ctx, "s1") == missing
      assert unlock(ctx, "s2", agent_id: agent2) == missing
      assert unlock(ctx, nil) == missing

      assert audit_actions(ctx.tenant.id, mine.id) == ["posted", "soft_lock_released"]

      remaining = ctx.tenant.id |> lock_rows(ctx.project.id) |> Enum.map(& &1.id)
      assert Enum.sort(remaining) == Enum.sort([peer_session.id, peer_agent.id])
    end

    test "a re-lock after unlock is a fresh :created (the row is really gone)" do
      ctx = setup_member()
      assert {:ok, first, :created} = take_lock(ctx)
      assert {:ok, _} = unlock(ctx, "sess-a")
      assert {:ok, second, :created} = take_lock(ctx)
      refute second.id == first.id
    end

    test "malformed ids are the same :not_found, never a raise" do
      ctx = setup_member()
      assert {:ok, _lock, :created} = take_lock(ctx)

      assert {:error, :not_found} =
               Coordination.unlock_file("not-a-uuid", ctx.agent_id, ctx.project.id, @target,
                 session_id: "sess-a"
               )

      assert {:error, :not_found} =
               Coordination.unlock_file(ctx.tenant.id, ctx.agent_id, "not-a-uuid", @target,
                 session_id: "sess-a"
               )

      assert [_still_there] = lock_rows(ctx.tenant.id, ctx.project.id)
    end

    test "a sibling session under the same agent key CAN release the peer's lock (agent scope)" do
      ctx = setup_member()

      assert {:ok, held, :created} = take_lock(ctx, session_id: "sess-a")
      assert [surfaced] = Coordination.active_locks(ctx.tenant.id, ctx.project.id)
      assert surfaced.session_id == "sess-a"

      assert {:ok, released} = unlock(ctx, surfaced.session_id)
      assert released.id == held.id
    end
  end

  describe "audit" do
    test "lock, refresh and unlock each write a channel_lock entry naming the target" do
      ctx = setup_member()

      assert {:ok, lock, :created} = take_lock(ctx)
      assert {:ok, _refreshed, :updated} = take_lock(ctx)
      assert {:ok, _released} = unlock(ctx, "sess-a")

      assert audit_actions(ctx.tenant.id, lock.id) == ["posted", "upserted", "soft_lock_released"]

      metadata =
        AdminRepo.all(
          from(a in AuditLog,
            where: a.tenant_id == ^ctx.tenant.id and a.entity_id == ^lock.id,
            select: a.metadata
          )
        )

      assert Enum.all?(metadata, &(Map.get(&1, "soft_lock_target") == @target))
    end
  end

  describe "active_locks_page/3 (TC-52.21.4)" do
    test "keeps the per-agent fairness cap and drops expired locks" do
      ctx = setup_member()
      quiet = fixture(:agent, %{tenant_id: ctx.tenant.id}).id
      make_member(ctx.tenant, ctx.project, quiet)

      for i <- 1..3 do
        assert {:ok, _, :created} =
                 take_lock(ctx, agent_id: quiet, session_id: "quiet", target: "lib/q#{i}.ex")
      end

      for i <- 1..25 do
        assert {:ok, _, :created} = take_lock(ctx, target: "lib/noisy#{i}.ex")
      end

      expired =
        fixture(:channel_lock, %{
          tenant_id: ctx.tenant.id,
          project_id: ctx.project.id,
          agent_id: quiet,
          expires_at: DateTime.add(DateTime.utc_now(), -60, :second)
        })

      assert {locks, false, true} =
               Coordination.active_locks_page(ctx.tenant.id, ctx.project.id, limit: 100)

      assert length(locks) == 23
      assert Enum.count(locks, &(&1.agent_id == ctx.agent_id)) == 20
      assert Enum.count(locks, &(&1.agent_id == quiet)) == 3
      refute expired.id in Enum.map(locks, & &1.id)
    end

    test "the fairness cap is NOT escapable by rotating the caller-supplied session_id" do
      ctx = setup_member()

      for i <- 1..25 do
        assert {:ok, _, :created} = take_lock(ctx, session_id: "rot-#{i}", target: "lib/n#{i}.ex")
      end

      {locks, _overflow?, holders_truncated?} =
        Coordination.active_locks_page(ctx.tenant.id, ctx.project.id, limit: 100)

      assert length(locks) == 20
      assert holders_truncated?
    end

    test "the page cap is clamped and overflow is reported; newest first" do
      ctx = setup_member()

      for n <- 1..3 do
        assert {:ok, _lock, :created} =
                 take_lock(ctx, target: "lib/f#{n}.ex", session_id: "s#{n}")
      end

      assert {[newest, _], true, false} =
               Coordination.active_locks_page(ctx.tenant.id, ctx.project.id, limit: 2)

      assert newest.target == "lib/f3.ex"

      assert {all, false, false} = Coordination.active_locks_page(ctx.tenant.id, ctx.project.id)
      assert length(all) == 3

      assert Coordination.clamp_active_locks_limit(1000) == 200
      assert Coordination.clamp_active_locks_limit(nil) == 100
      assert Coordination.clamp_active_locks_limit("5") == 5
      assert Coordination.clamp_active_locks_limit("junk") == 100
    end

    test "a malformed tenant/project id yields an empty set, never a raise" do
      ctx = setup_member()
      assert Coordination.active_locks("not-a-uuid", ctx.project.id) == []
      assert Coordination.active_locks(ctx.tenant.id, "not-a-uuid") == []
      assert Coordination.active_locks(ctx.tenant.id, nil) == []
    end

    test "an expired lock is not surfaced, and the sweeper deletes it" do
      ctx = setup_member()
      assert {:ok, lock, :created} = take_lock(ctx)

      {1, _} =
        AdminRepo.update_all(from(l in ChannelLock, where: l.id == ^lock.id),
          set: [expires_at: DateTime.add(DateTime.utc_now(), -60, :second)]
        )

      assert Coordination.active_locks(ctx.tenant.id, ctx.project.id) == []
      assert [_row] = lock_rows(ctx.tenant.id, ctx.project.id)

      assert :ok = ChannelPostSweeper.perform(%Oban.Job{args: %{}})
      assert lock_rows(ctx.tenant.id, ctx.project.id) == []
    end
  end

  describe "target path normalization" do
    test "different spellings of one path collapse to ONE slot, for lock and unlock" do
      ctx = setup_member()

      assert {:ok, lock, :created} = take_lock(ctx, target: "lib/foo.ex")

      for spelling <- ["./lib/foo.ex", "lib//foo.ex", "/lib/foo.ex", "lib/./foo.ex"] do
        assert {:ok, same, :updated} = take_lock(ctx, target: spelling)
        assert same.id == lock.id
      end

      assert [%ChannelLock{target: "lib/foo.ex"}] = lock_rows(ctx.tenant.id, ctx.project.id)

      assert {:ok, _released} = unlock(ctx, "sess-a", target: "./lib//foo.ex")
      assert Coordination.active_locks(ctx.tenant.id, ctx.project.id) == []
    end

    test "a target that normalizes to nothing is rejected" do
      ctx = setup_member()
      assert {:error, :invalid_target} = take_lock(ctx, target: "///")
      assert {:error, :invalid_target} = take_lock(ctx, target: " ./ ")
    end
  end

  describe "the message path has no lock branch (TC-52.21.6)" do
    test "channel_recent returns the post only, with no lock fields" do
      ctx = setup_member()
      assert {:ok, _lock, :created} = take_lock(ctx)

      assert {:ok, post, :created} =
               Coordination.post(ctx.tenant.id, ctx.agent_id, :agent, %{
                 project_id: ctx.project.id,
                 body: "an ordinary coordination post",
                 audit: audit()
               })

      assert {[row], false, nil} = Coordination.recent_page(ctx.tenant.id, ctx.project.id, [])
      assert row.id == post.id
      refute Map.has_key?(row, :lock)
      refute Map.has_key?(row, :lock_target)
    end

    test "the deleted lock helpers are gone" do
      Code.ensure_loaded!(Coordination)

      refute function_exported?(Coordination, :soft_lock_row?, 1)
      refute function_exported?(Coordination, :lock_key_prefix, 0)
    end

    test "an ordinary post keyed claim: is an ordinary 30-day post, not a lock" do
      ctx = setup_member()
      before = DateTime.utc_now()

      assert {:ok, post, :created} =
               Coordination.post(ctx.tenant.id, ctx.agent_id, :agent, %{
                 project_id: ctx.project.id,
                 body: "working state",
                 key: "claim:story-812",
                 session_id: "sess-a",
                 audit: audit()
               })

      assert DateTime.diff(post.expires_at, before) > 29 * 24 * 3600

      assert {:ok, _created} =
               Coordination.create_post(ctx.tenant.id, ctx.project.id, ctx.agent_id, %{
                 key: "claim:story-813",
                 session_id: "sess-a",
                 body: "ordinary post"
               })

      assert Coordination.active_locks(ctx.tenant.id, ctx.project.id) == []
      assert lock_rows(ctx.tenant.id, ctx.project.id) == []
    end
  end

  describe "tenant isolation (TC-52.21.9)" do
    test "another tenant can neither read nor release tenant A's lock" do
      a = setup_member()
      b = setup_member()

      assert {:ok, a_lock, :created} = take_lock(a, target: "lib/a.ex", session_id: "s1")

      assert Coordination.active_locks_page(b.tenant.id, a.project.id, []) == {[], false, false}

      assert {:error, :not_found} =
               Coordination.unlock_file(b.tenant.id, b.agent_id, a.project.id, "lib/a.ex",
                 session_id: "s1"
               )

      # Tenant A's own agent id under tenant B's tenant id is no key either.
      assert {:error, :not_found} =
               Coordination.unlock_file(b.tenant.id, a.agent_id, a.project.id, "lib/a.ex",
                 session_id: "s1"
               )

      assert [%ChannelLock{id: id}] = lock_rows(a.tenant.id, a.project.id)
      assert id == a_lock.id
    end
  end
end
