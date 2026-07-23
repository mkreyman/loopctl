defmodule Loopctl.CoordinationSoftLockTest do
  @moduledoc """
  US-40.4 — ADVISORY file soft-locks (`Coordination.lock_file/5`,
  `unlock_file/5`, `active_locks/3`).

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
      from(p in ChannelPost,
        where: p.tenant_id == ^tenant_id and p.project_id == ^project_id,
        where: like(p.key, "claim:%"),
        order_by: [asc: p.inserted_at]
      )
    )
  end

  defp audit_actions(tenant_id, entity_id) do
    AdminRepo.all(
      from(a in AuditLog,
        where: a.tenant_id == ^tenant_id and a.entity_type == "channel_post",
        where: a.entity_id == ^entity_id,
        order_by: [asc: a.inserted_at],
        select: a.action
      )
    )
  end

  describe "lock_file/5 — TC-40.4.1" do
    test "writes a claim-keyed post with a file ref and a clamped short TTL, and surfaces it" do
      ctx = setup_member()
      before = DateTime.utc_now()

      assert {:ok, post, :created} = take_lock(ctx, ttl_seconds: 600)

      assert post.key == "claim:#{@target}"
      assert post.refs == [%{"type" => "file", "value" => @target}]

      # AC-40.4.1: the TTL is the ONE caller-influenced expires_at, and 600s is
      # inside the [60, 3600] clamp so it applies verbatim.
      assert_in_delta DateTime.diff(post.expires_at, before), 600, 5

      # AC-40.4.2: it is surfaced as an active lock, and the call did not block.
      assert [surfaced] = Coordination.active_locks(ctx.tenant.id, ctx.project.id)
      assert surfaced.id == post.id
      assert surfaced.target == @target
      assert surfaced.agent_id == ctx.agent_id
      assert surfaced.session_id == "sess-a"
    end

    test "an ordinary channel_recent read also sees the live lock" do
      ctx = setup_member()
      assert {:ok, post, :created} = take_lock(ctx)

      assert ctx.tenant.id
             |> Coordination.recent(ctx.project.id)
             |> Enum.any?(&(&1.id == post.id))
    end

    test "a blank / oversized / non-binary target is rejected with :invalid_target" do
      ctx = setup_member()

      assert {:error, :invalid_target} = take_lock(ctx, target: "   ")
      assert {:error, :invalid_target} = take_lock(ctx, target: "")
      assert {:error, :invalid_target} = take_lock(ctx, target: nil)
      assert {:error, :invalid_target} = take_lock(ctx, target: 42)
      assert {:error, :invalid_target} = take_lock(ctx, target: String.duplicate("a", 195))

      # 194 bytes is the boundary that still fits the 200-byte key column.
      assert {:ok, _post, :created} = take_lock(ctx, target: String.duplicate("a", 194))
    end
  end

  describe "TTL clamping" do
    test "the clamp bounds are exact: [60, 3600] seconds, default 900" do
      assert Coordination.lock_ttl_seconds(1) == 60
      assert Coordination.lock_ttl_seconds(59) == 60
      assert Coordination.lock_ttl_seconds(60) == 60
      assert Coordination.lock_ttl_seconds(3600) == 3600
      assert Coordination.lock_ttl_seconds(3601) == 3600
      assert Coordination.lock_ttl_seconds(999_999) == 3600
      assert Coordination.lock_ttl_seconds(0) == 60
      assert Coordination.lock_ttl_seconds(-5) == 60
      assert Coordination.lock_ttl_seconds(nil) == 900
      assert Coordination.lock_ttl_seconds("not-a-number") == 900
      assert Coordination.lock_ttl_seconds("12abc") == 900
      assert Coordination.lock_ttl_seconds(%{}) == 900
      # An integer-shaped STRING parses and is then clamped like an integer.
      assert Coordination.lock_ttl_seconds("120") == 120
      assert Coordination.lock_ttl_seconds("10") == 60
      assert Coordination.lock_ttl_seconds("99999") == 3600
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

    test "a ttl override does NOT apply to an ordinary (non-claim:) post — it keeps 30d retention" do
      ctx = setup_member()
      before = DateTime.utc_now()

      assert {:ok, plain, :created} =
               Coordination.post(ctx.tenant.id, ctx.agent_id, :agent, %{
                 project_id: ctx.project.id,
                 body: "working on something",
                 key: "wip:something",
                 session_id: "sess-a",
                 ttl_seconds: 60,
                 audit: audit()
               })

      assert DateTime.diff(plain.expires_at, before) > 29 * 24 * 3600

      assert {:ok, keyless, :created} =
               Coordination.post(ctx.tenant.id, ctx.agent_id, :agent, %{
                 project_id: ctx.project.id,
                 body: "keyless note",
                 ttl_seconds: 60,
                 audit: audit()
               })

      assert DateTime.diff(keyless.expires_at, before) > 29 * 24 * 3600
    end

    # Review #451 (high): the short TTL used to be routed on the CALLER-CHOSEN key
    # prefix, so an ordinary post innocently keyed `claim:story-812` was silently cut
    # from 30 days to 900s AND surfaced as a bogus file lock. The prefix is now a
    # RESERVED namespace on the generic write path, and the short TTL is driven by a
    # private marker only `lock_file/5` stamps.
    test "the claim: key namespace is RESERVED on the generic post path (422, not a silent 900s TTL)" do
      ctx = setup_member()

      assert {:error, :unprocessable_entity, message} =
               Coordination.post(ctx.tenant.id, ctx.agent_id, :agent, %{
                 project_id: ctx.project.id,
                 body: "an ordinary keyed slot that happens to be named claim:...",
                 key: "claim:story-812",
                 session_id: "sess-a",
                 ttl_seconds: 60,
                 audit: audit()
               })

      assert message =~ "reserved"

      # Nothing was written, so nothing can masquerade as a live lock.
      assert lock_rows(ctx.tenant.id, ctx.project.id) == []
      assert Coordination.active_locks(ctx.tenant.id, ctx.project.id) == []
    end

    test "the reserved-prefix guard does not fire for the lock path itself" do
      ctx = setup_member()
      assert {:ok, post, :created} = take_lock(ctx)
      assert post.key == "claim:#{@target}"
    end

    # Review #451 (medium): a surrogate session is minted fresh per write, so a
    # session-less lock is neither refreshable nor releasable — reject it instead.
    test "a lock write with no session_id is REJECTED rather than given a surrogate slot" do
      ctx = setup_member()

      assert {:error, :missing_session} = take_lock(ctx, session_id: nil)
      assert {:error, :missing_session} = take_lock(ctx, session_id: "   ")
      assert lock_rows(ctx.tenant.id, ctx.project.id) == []
    end
  end

  describe "refresh (same slot)" do
    test "the same (tenant, project, agent, session, key) UPSERTS in place — one row, refreshed TTL" do
      ctx = setup_member()

      assert {:ok, first, :created} = take_lock(ctx, ttl_seconds: 60)
      assert {:ok, second, :updated} = take_lock(ctx, ttl_seconds: 3600)

      assert second.id == first.id
      assert DateTime.compare(second.expires_at, first.expires_at) == :gt
      assert DateTime.compare(second.updated_at, first.updated_at) in [:gt, :eq]
      assert [_only_one] = lock_rows(ctx.tenant.id, ctx.project.id)
    end
  end

  describe "advisory: never blocks — TC-40.4.4" do
    test "two sessions of the same agent hold a lock on the SAME file; both succeed and surface" do
      ctx = setup_member()

      assert {:ok, a, :created} = take_lock(ctx, session_id: "sess-a")
      assert {:ok, b, :created} = take_lock(ctx, session_id: "sess-b")

      refute a.id == b.id
      assert length(lock_rows(ctx.tenant.id, ctx.project.id)) == 2

      ids = ctx.tenant.id |> Coordination.active_locks(ctx.project.id) |> Enum.map(& &1.id)
      assert a.id in ids
      assert b.id in ids
    end

    test "two DIFFERENT agents lock the same file; neither is rejected and both surface" do
      ctx = setup_member()
      agent_b = fixture(:agent, %{tenant_id: ctx.tenant.id}).id
      make_member(ctx.tenant, ctx.project, agent_b)

      assert {:ok, a, :created} = take_lock(ctx, session_id: "sess-a")
      assert {:ok, b, :created} = take_lock(ctx, agent_id: agent_b, session_id: "sess-b")

      refute a.agent_id == b.agent_id

      locks = Coordination.active_locks(ctx.tenant.id, ctx.project.id)
      assert length(locks) == 2
      assert Enum.all?(locks, &(&1.target == @target))
    end
  end

  describe "unlock_file/5 — TC-40.4.3" do
    test "removes the caller's own lock only; a peer session's lock on the same target survives" do
      ctx = setup_member()

      assert {:ok, mine, :created} = take_lock(ctx, session_id: "sess-a")
      assert {:ok, peer, :created} = take_lock(ctx, session_id: "sess-b")

      assert {:ok, deleted} =
               Coordination.unlock_file(ctx.tenant.id, ctx.agent_id, ctx.project.id, @target,
                 session_id: "sess-a",
                 audit: audit()
               )

      assert deleted.id == mine.id
      assert [remaining] = lock_rows(ctx.tenant.id, ctx.project.id)
      assert remaining.id == peer.id
      assert [surfaced] = Coordination.active_locks(ctx.tenant.id, ctx.project.id)
      assert surfaced.id == peer.id
    end

    test "a re-lock after unlock is a fresh :created (the row is really gone, not tombstoned)" do
      ctx = setup_member()
      assert {:ok, first, :created} = take_lock(ctx)
      assert {:ok, _} = unlock(ctx, "sess-a")
      assert {:ok, second, :created} = take_lock(ctx)
      refute second.id == first.id
    end

    test "oracle-safe :not_found for nonexistent, another session's, another agent's, and cross-tenant locks" do
      ctx = setup_member()
      other = setup_member()
      agent_b = fixture(:agent, %{tenant_id: ctx.tenant.id}).id
      make_member(ctx.tenant, ctx.project, agent_b)

      assert {:ok, _post, :created} = take_lock(ctx, session_id: "sess-a")

      # never locked
      assert {:error, :not_found} = unlock(ctx, "sess-a", target: "lib/never.ex")
      # someone else's session
      assert {:error, :not_found} = unlock(ctx, "sess-zzz")
      # another agent in the same tenant/project
      assert {:error, :not_found} =
               Coordination.unlock_file(ctx.tenant.id, agent_b, ctx.project.id, @target,
                 session_id: "sess-a"
               )

      # another tenant's agent
      assert {:error, :not_found} =
               Coordination.unlock_file(other.tenant.id, other.agent_id, ctx.project.id, @target,
                 session_id: "sess-a"
               )

      # missing session id / malformed ids / blank target — all the same shape
      assert {:error, :not_found} = unlock(ctx, nil)
      assert {:error, :not_found} = unlock(ctx, "sess-a", target: "  ")

      assert {:error, :not_found} =
               Coordination.unlock_file("not-a-uuid", ctx.agent_id, ctx.project.id, @target,
                 session_id: "sess-a"
               )

      assert {:error, :not_found} =
               Coordination.unlock_file(ctx.tenant.id, ctx.agent_id, "not-a-uuid", @target,
                 session_id: "sess-a"
               )

      # the lock itself is untouched by every failed attempt
      assert [_still_there] = lock_rows(ctx.tenant.id, ctx.project.id)
    end
  end

  describe "self-expiry — TC-40.4.2" do
    test "an expired lock is not surfaced by the live read, and the sweeper deletes it" do
      ctx = setup_member()
      assert {:ok, post, :created} = take_lock(ctx)

      # Force the lock past its TTL (the write path clamps, so expire it directly).
      past = DateTime.add(DateTime.utc_now(), -60, :second)

      {1, _} =
        AdminRepo.update_all(
          from(p in ChannelPost, where: p.id == ^post.id),
          set: [expires_at: past]
        )

      # The live read filters on expires_at INDEPENDENTLY of the sweep, so the lock
      # disappears immediately — a crashed session can never hold a file.
      assert Coordination.active_locks(ctx.tenant.id, ctx.project.id) == []
      # ...and the row is still there until the sweep runs.
      assert [_row] = lock_rows(ctx.tenant.id, ctx.project.id)

      assert :ok = ChannelPostSweeper.perform(%Oban.Job{args: %{}})
      assert lock_rows(ctx.tenant.id, ctx.project.id) == []
    end
  end

  describe "active_locks/3" do
    test "returns ONLY claim:-prefixed live posts (handoffs and keyless posts are excluded)" do
      ctx = setup_member()

      assert {:ok, lock_post, :created} = take_lock(ctx)

      {:ok, handoff, :created} =
        Coordination.post(ctx.tenant.id, ctx.agent_id, :agent, %{
          project_id: ctx.project.id,
          body: "handoff body",
          key: "handoff:repo#812",
          session_id: "sess-a",
          audit: audit()
        })

      {:ok, keyless, :created} =
        Coordination.post(ctx.tenant.id, ctx.agent_id, :agent, %{
          project_id: ctx.project.id,
          body: "just a note",
          audit: audit()
        })

      ids = ctx.tenant.id |> Coordination.active_locks(ctx.project.id) |> Enum.map(& &1.id)
      assert ids == [lock_post.id]
      refute handoff.id in ids
      refute keyless.id in ids

      # Handoff discovery is unchanged by the presence of a lock.
      handoff_ids =
        ctx.tenant.id |> Coordination.directed_handoffs(ctx.project.id) |> Enum.map(& &1.id)

      assert handoff_ids == [handoff.id]
    end

    test "tenant isolation: tenant A never sees tenant B's locks" do
      a = setup_member()
      b = setup_member()

      assert {:ok, a_lock, :created} = take_lock(a)
      assert {:ok, b_lock, :created} = take_lock(b)

      assert [only_a] = Coordination.active_locks(a.tenant.id, a.project.id)
      assert only_a.id == a_lock.id

      assert [only_b] = Coordination.active_locks(b.tenant.id, b.project.id)
      assert only_b.id == b_lock.id

      # Tenant A asking for tenant B's project id gets nothing (no cross-tenant read).
      assert Coordination.active_locks(a.tenant.id, b.project.id) == []
    end

    test "a malformed tenant/project id yields an empty set, never a raise" do
      ctx = setup_member()
      assert Coordination.active_locks("not-a-uuid", ctx.project.id) == []
      assert Coordination.active_locks(ctx.tenant.id, "not-a-uuid") == []
      assert Coordination.active_locks(ctx.tenant.id, nil) == []
    end

    test "the page cap is clamped and overflow is reported" do
      ctx = setup_member()

      for n <- 1..3 do
        assert {:ok, _post, :created} =
                 take_lock(ctx, target: "lib/f#{n}.ex", session_id: "s#{n}")
      end

      assert {locks, true} =
               Coordination.active_locks_page(ctx.tenant.id, ctx.project.id, limit: 2)

      assert length(locks) == 2

      assert {all, false} = Coordination.active_locks_page(ctx.tenant.id, ctx.project.id)
      assert length(all) == 3

      assert Coordination.clamp_active_locks_limit(1000) == 200
      assert Coordination.clamp_active_locks_limit(nil) == 100
      assert Coordination.clamp_active_locks_limit("5") == 5
      assert Coordination.clamp_active_locks_limit("junk") == 100
    end
  end

  describe "authorization (shared US-40.D3 gate)" do
    test "a non-member :agent locking a sibling project gets the byte-identical :not_found" do
      ctx = setup_member()
      sibling = fixture(:project, %{tenant_id: ctx.tenant.id})

      assert {:error, :not_found} = take_lock(ctx, project_id: sibling.id)
      # Byte-identical to a nonexistent / cross-tenant project.
      assert {:error, :not_found} = take_lock(ctx, project_id: Ecto.UUID.generate())

      other = setup_member()
      assert {:error, :not_found} = take_lock(ctx, project_id: other.project.id)
    end

    test "a role >= :user bypasses the membership gate" do
      ctx = setup_member()
      sibling = fixture(:project, %{tenant_id: ctx.tenant.id})

      assert {:ok, _post, :created} = take_lock(ctx, project_id: sibling.id, role: :user)
    end
  end

  # Review #451 (medium): the ownership guarantee is per-AGENT, not per-session —
  # `session_id` is caller-supplied and `active_locks/3` publishes it. This test
  # pins the ACTUAL behaviour (the docs/tool descriptions were narrowed to match);
  # the pre-existing negative case used "sess-zzz", a session that never existed,
  # so it never exercised a real sibling session.
  describe "release scope (agent-scoped, NOT session-scoped)" do
    test "a REAL sibling session under the same agent key can release the peer's lock" do
      ctx = setup_member()

      assert {:ok, held, :created} = take_lock(ctx, session_id: "sess-a")

      # Session B discovers A's session id straight from the published read.
      assert [surfaced] = Coordination.active_locks(ctx.tenant.id, ctx.project.id)
      assert surfaced.session_id == "sess-a"

      assert {:ok, released} = unlock(ctx, surfaced.session_id)
      assert released.id == held.id
      assert Coordination.active_locks(ctx.tenant.id, ctx.project.id) == []
    end

    test "a DIFFERENT agent in the same tenant still cannot release it" do
      ctx = setup_member()
      agent_b = fixture(:agent, %{tenant_id: ctx.tenant.id}).id
      make_member(ctx.tenant, ctx.project, agent_b)

      assert {:ok, _held, :created} = take_lock(ctx, session_id: "sess-a")

      assert {:error, :not_found} =
               Coordination.unlock_file(ctx.tenant.id, agent_b, ctx.project.id, @target,
                 session_id: "sess-a"
               )

      assert [_still_held] = Coordination.active_locks(ctx.tenant.id, ctx.project.id)
    end
  end

  # Review #451 (medium x2): locks are the highest-churn write on the bus, so they
  # get a BOUNDED share of `recent_page/3` and a per-holder fairness budget on the
  # pinned read — otherwise one noisy locker crowds out both real coordination posts
  # and every peer's lock.
  describe "crowding bounds" do
    test "recent_page admits only the newest few locks, so real posts keep their budget" do
      ctx = setup_member()

      for i <- 1..12 do
        assert {:ok, _lock, :created} = take_lock(ctx, target: "lib/f#{i}.ex")
      end

      for i <- 1..12 do
        assert {:ok, _post, :created} =
                 Coordination.post(ctx.tenant.id, ctx.agent_id, :agent, %{
                   project_id: ctx.project.id,
                   body: "genuine coordination post #{i}",
                   audit: audit()
                 })
      end

      page = Coordination.recent(ctx.tenant.id, ctx.project.id, limit: 25)
      {locks, plain} = Enum.split_with(page, &String.starts_with?(&1.key || "", "claim:"))

      assert length(locks) <= 5
      # Every non-lock post still fits the page — none was crowded out.
      assert length(plain) == 12
    end

    test "the pinned lock read caps ONE (agent, session) holder so peers stay visible" do
      ctx = setup_member()
      quiet_agent = fixture(:agent, %{tenant_id: ctx.tenant.id}).id
      make_member(ctx.tenant, ctx.project, quiet_agent)

      # The quiet peer locks FIRST, so a pure newest-first truncation would evict it.
      assert {:ok, peer_lock, :created} =
               take_lock(ctx, agent_id: quiet_agent, session_id: "sess-quiet", target: "lib/q.ex")

      for i <- 1..25 do
        assert {:ok, _lock, :created} = take_lock(ctx, target: "lib/noisy#{i}.ex")
      end

      locks = Coordination.active_locks(ctx.tenant.id, ctx.project.id, limit: 21)
      noisy = Enum.filter(locks, &(&1.session_id == "sess-a"))

      assert length(noisy) == 20
      assert peer_lock.id in Enum.map(locks, & &1.id)
    end
  end

  describe "audit" do
    test "lock and unlock each write an audit entry naming the file target" do
      ctx = setup_member()

      assert {:ok, post, :created} = take_lock(ctx)
      assert audit_actions(ctx.tenant.id, post.id) == ["posted"]

      assert {:ok, _refreshed, :updated} = take_lock(ctx)
      assert audit_actions(ctx.tenant.id, post.id) == ["posted", "upserted"]

      # Review #451: the release action is DISTINCT from the "deleted" action the
      # US-39.7 secret-redaction path uses, so routine lock churn cannot dilute
      # that security signal.
      assert {:ok, _deleted} = unlock(ctx, "sess-a")
      assert audit_actions(ctx.tenant.id, post.id) == ["posted", "upserted", "soft_lock_released"]

      metadata =
        AdminRepo.all(
          from(a in AuditLog,
            where: a.tenant_id == ^ctx.tenant.id and a.entity_id == ^post.id,
            select: a.metadata
          )
        )

      assert Enum.all?(metadata, &(Map.get(&1, "soft_lock_target") == @target))
    end
  end

  defp unlock(ctx, session_id, opts \\ []) do
    Coordination.unlock_file(
      ctx.tenant.id,
      ctx.agent_id,
      ctx.project.id,
      Keyword.get(opts, :target, @target),
      session_id: session_id,
      audit: audit()
    )
  end
end
