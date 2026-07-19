defmodule Loopctl.CoordinationTest do
  use Loopctl.DataCase, async: true

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.Audit.AuditLog
  alias Loopctl.Coordination
  alias Loopctl.Coordination.ChannelPost
  alias Loopctl.Repo

  describe "create_post/4" do
    test "inserts with programmatic tenant/project/agent/expires and cast body" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      agent_id = fixture(:agent, %{tenant_id: tenant.id}).id

      assert {:ok, post} =
               Coordination.create_post(tenant.id, project.id, agent_id, %{
                 "body" => "pushed PR #107, CI green"
               })

      assert post.tenant_id == tenant.id
      assert post.project_id == project.id
      assert post.agent_id == agent_id
      assert post.body == "pushed PR #107, CI green"
      assert is_nil(post.key)
      assert is_nil(post.refs)

      # expires_at is ~30 days out (server-set, uniform retention).
      expected = DateTime.add(DateTime.utc_now(), Coordination.retention_days() * 86_400, :second)
      assert_in_delta DateTime.to_unix(post.expires_at), DateTime.to_unix(expected), 120
    end

    test "a mispaired project (belongs to another tenant) returns {:error, :not_found}" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      project_b = fixture(:project, %{tenant_id: tenant_b.id})

      assert {:error, :not_found} =
               Coordination.create_post(tenant_a.id, project_b.id, Ecto.UUID.generate(), %{
                 "body" => "cross-tenant attempt"
               })
    end

    test "a mispaired agent (belongs to another tenant) returns {:error, :not_found}" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      project_a = fixture(:project, %{tenant_id: tenant_a.id})
      agent_b = fixture(:agent, %{tenant_id: tenant_b.id}).id

      assert {:error, :not_found} =
               Coordination.create_post(tenant_a.id, project_a.id, agent_b, %{
                 "body" => "cross-tenant agent attribution"
               })
    end

    test "a blocked secret emits the security signal once, at rejection time" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      agent_id = fixture(:agent, %{tenant_id: tenant.id}).id

      tenant_id = tenant.id
      handler_id = "coord-secret-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:loopctl, :coordination, :secret_blocked],
        fn _event, measurements, meta, _cfg ->
          if meta[:tenant_id] == tenant_id,
            do: send(test_pid, {:secret_blocked, measurements, meta})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert {:error, %Ecto.Changeset{}} =
               Coordination.create_post(tenant.id, project.id, agent_id, %{
                 "body" => "sk-" <> String.duplicate("a", 30)
               })

      assert_receive {:secret_blocked, %{count: 1}, %{field: :body}}
      # Exactly one emission for the single rejected field — no double-count.
      refute_receive {:secret_blocked, _, _}, 50
    end

    test "a duplicate same-session keyed post returns {:error, changeset}, not a raise" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      agent_id = fixture(:agent, %{tenant_id: tenant.id}).id
      attrs = %{"body" => "goal", "session_id" => "S1", "key" => "session_goal"}

      assert {:ok, _post} = Coordination.create_post(tenant.id, project.id, agent_id, attrs)

      assert {:error, %Ecto.Changeset{} = cs} =
               Coordination.create_post(tenant.id, project.id, agent_id, attrs)

      assert %{key: _} = errors_on(cs)
    end

    test "accepts a typed-open refs list and round-trips it through the DB" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      agent_id = fixture(:agent, %{tenant_id: tenant.id}).id

      refs = [
        %{"type" => "pr", "value" => "107"},
        %{"type" => "branch", "value" => "epic-39-us-39.1"}
      ]

      assert {:ok, post} =
               Coordination.create_post(tenant.id, project.id, agent_id, %{
                 "body" => "see the fix",
                 "refs" => refs
               })

      assert post.refs == refs
      # persisted list survives a fresh read (RefsList.load round-trip)
      assert [%ChannelPost{refs: ^refs}] = Coordination.recent(tenant.id, project.id)
    end
  end

  describe "tenant isolation (both paths)" do
    test "recent/3 (AdminRepo + explicit filter) and RLS Repo both hide another tenant's posts" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      project_a = fixture(:project, %{tenant_id: tenant_a.id})
      agent_a = fixture(:agent, %{tenant_id: tenant_a.id}).id

      {:ok, _post} =
        Coordination.create_post(tenant_a.id, project_a.id, agent_a, %{
          "body" => "tenant A only"
        })

      # AdminRepo path: tenant_b's explicit filter yields zero rows for A's project.
      assert Coordination.recent(tenant_b.id, project_a.id) == []
      # And tenant_a sees its own post.
      assert [%ChannelPost{body: "tenant A only"}] =
               Coordination.recent(tenant_a.id, project_a.id)

      # RLS Repo path (belt-and-suspenders): scoped to tenant_b, the row is invisible.
      {:ok, rows} =
        Repo.with_tenant(tenant_b.id, fn ->
          Repo.all(from(p in ChannelPost, where: p.project_id == ^project_a.id))
        end)

      assert rows == []
    end
  end

  describe "recent/3 limit and guard behavior" do
    test "limit: 0 returns an empty list (honours the explicit request)" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      agent_id = fixture(:agent, %{tenant_id: tenant.id}).id

      {:ok, _} =
        Coordination.create_post(tenant.id, project.id, agent_id, %{"body" => "hi"})

      assert Coordination.recent(tenant.id, project.id, limit: 0) == []
    end

    test "limit: \"0\" (string, as a ?limit= query param would arrive) returns []" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      agent_id = fixture(:agent, %{tenant_id: tenant.id}).id

      {:ok, _} =
        Coordination.create_post(tenant.id, project.id, agent_id, %{"body" => "hi"})

      assert Coordination.recent(tenant.id, project.id, limit: "0") == []
    end

    test "a garbage (non-integer) limit string falls back to the default" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      agent_id = fixture(:agent, %{tenant_id: tenant.id}).id

      {:ok, _} =
        Coordination.create_post(tenant.id, project.id, agent_id, %{"body" => "hi"})

      assert [%ChannelPost{}] = Coordination.recent(tenant.id, project.id, limit: "abc")
    end

    test "a malformed (non-UUID) project_id yields [] rather than a CastError" do
      tenant = fixture(:tenant)
      assert Coordination.recent(tenant.id, "not-a-uuid") == []
    end

    test "a malformed (non-UUID) tenant_id yields []" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      assert Coordination.recent("not-a-uuid", project.id) == []
    end

    test "a blank key posts as a keyless append-only post (no slot collision)" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      agent_id = fixture(:agent, %{tenant_id: tenant.id}).id

      assert {:ok, p1} =
               Coordination.create_post(tenant.id, project.id, agent_id, %{
                 "body" => "one",
                 "key" => ""
               })

      assert is_nil(p1.key)

      # A second blank-key post in the same session must NOT collide.
      assert {:ok, _p2} =
               Coordination.create_post(tenant.id, project.id, agent_id, %{
                 "body" => "two",
                 "key" => ""
               })
    end
  end

  describe "recent/3 since and limit contract (US-39.3)" do
    setup do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      agent_id = fixture(:agent, %{tenant_id: tenant.id}).id
      %{tenant: tenant, project: project, agent_id: agent_id}
    end

    defp seed_post(tenant, project, agent_id, body, inserted_at) do
      # Seed a post at a controlled inserted_at/updated_at so ordering + since
      # deltas are deterministic (create_post always stamps "now").
      {:ok, post} =
        Coordination.create_post(tenant.id, project.id, agent_id, %{"body" => body})

      {:ok, post} =
        post
        |> Ecto.Changeset.change(inserted_at: inserted_at, updated_at: inserted_at)
        |> AdminRepo.update()

      post
    end

    test "orders newest-first by inserted_at", %{
      tenant: tenant,
      project: project,
      agent_id: agent_id
    } do
      base = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      t1 = DateTime.add(base, -300, :second)
      t2 = DateTime.add(base, -200, :second)
      t3 = DateTime.add(base, -100, :second)

      seed_post(tenant, project, agent_id, "one", t1)
      seed_post(tenant, project, agent_id, "two", t2)
      seed_post(tenant, project, agent_id, "three", t3)

      bodies = tenant.id |> Coordination.recent(project.id) |> Enum.map(& &1.body)
      assert bodies == ["three", "two", "one"]
    end

    test "since filters on GREATEST(inserted_at, updated_at) > since", %{
      tenant: tenant,
      project: project,
      agent_id: agent_id
    } do
      base = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      t1 = DateTime.add(base, -300, :second)
      t2 = DateTime.add(base, -200, :second)
      t3 = DateTime.add(base, -100, :second)

      seed_post(tenant, project, agent_id, "old", t1)
      seed_post(tenant, project, agent_id, "new", t3)

      bodies =
        tenant.id |> Coordination.recent(project.id, since: t2) |> Enum.map(& &1.body)

      assert bodies == ["new"]
    end

    test "since surfaces a slot whose updated_at (not inserted_at) advanced past since", %{
      tenant: tenant,
      project: project,
      agent_id: agent_id
    } do
      base = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      old = DateTime.add(base, -300, :second)
      since = DateTime.add(base, -200, :second)
      touched = DateTime.add(base, -100, :second)

      # inserted_at predates `since`, but updated_at (a later upsert) is after it —
      # GREATEST(inserted_at, updated_at) surfaces it as a delta.
      {:ok, post} =
        Coordination.create_post(tenant.id, project.id, agent_id, %{"body" => "slot"})

      {:ok, _} =
        post
        |> Ecto.Changeset.change(inserted_at: old, updated_at: touched)
        |> AdminRepo.update()

      bodies =
        tenant.id |> Coordination.recent(project.id, since: since) |> Enum.map(& &1.body)

      assert bodies == ["slot"]
    end

    test "since accepts an ISO8601 string (as a ?since= query param arrives)", %{
      tenant: tenant,
      project: project,
      agent_id: agent_id
    } do
      base = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      t1 = DateTime.add(base, -300, :second)
      t2 = DateTime.add(base, -200, :second)
      t3 = DateTime.add(base, -100, :second)

      seed_post(tenant, project, agent_id, "old", t1)
      seed_post(tenant, project, agent_id, "new", t3)

      bodies =
        tenant.id
        |> Coordination.recent(project.id, since: DateTime.to_iso8601(t2))
        |> Enum.map(& &1.body)

      assert bodies == ["new"]
    end

    test "since accepts an OFFSET-LESS ISO8601 string, interpreted as UTC", %{
      tenant: tenant,
      project: project,
      agent_id: agent_id
    } do
      base = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      t1 = DateTime.add(base, -300, :second)
      t2 = DateTime.add(base, -200, :second)
      t3 = DateTime.add(base, -100, :second)

      seed_post(tenant, project, agent_id, "old", t1)
      seed_post(tenant, project, agent_id, "new", t3)

      # A hand-crafted / tool-supplied offset-less instant (no `Z`/`+HH:MM`) must
      # STILL apply the delta filter (interpreted as UTC), not silently degrade to
      # "no filter" and return the whole channel. `NaiveDateTime.to_iso8601/1`
      # emits exactly this offset-less form.
      offset_less = NaiveDateTime.to_iso8601(DateTime.to_naive(t2))
      refute offset_less =~ ~r/(Z|[+-]\d\d:\d\d)$/

      bodies =
        tenant.id
        |> Coordination.recent(project.id, since: offset_less)
        |> Enum.map(& &1.body)

      assert bodies == ["new"]
    end

    test "a malformed since string is a no-op filter (not an error)", %{
      tenant: tenant,
      project: project,
      agent_id: agent_id
    } do
      seed_post(
        tenant,
        project,
        agent_id,
        "a",
        DateTime.utc_now() |> DateTime.truncate(:microsecond)
      )

      assert [%ChannelPost{}] = Coordination.recent(tenant.id, project.id, since: "not-a-date")
    end

    test "a date-only since (wrong granularity) is a no-op filter, returns the whole channel", %{
      tenant: tenant,
      project: project,
      agent_id: agent_id
    } do
      base = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      seed_post(tenant, project, agent_id, "old", DateTime.add(base, -300, :second))
      seed_post(tenant, project, agent_id, "new", DateTime.add(base, -100, :second))

      # "2026-07-18" is a valid ISO8601 DATE but not an INSTANT: it resolves to
      # neither an offset-bearing nor an offset-less DateTime, so the delta filter
      # is a no-op and the WHOLE live channel comes back (documented contract —
      # never a 400, never a silent partial delta). Supply a full instant to
      # actually get a delta.
      date_only = base |> DateTime.to_date() |> Date.to_iso8601()
      refute date_only =~ ~r/T/

      bodies =
        tenant.id
        |> Coordination.recent(project.id, since: date_only)
        |> Enum.map(& &1.body)
        |> Enum.sort()

      assert bodies == ["new", "old"]
    end

    test "delta ORDER BY GREATEST keeps a re-touched slot from being truncated by limit", %{
      tenant: tenant,
      project: project,
      agent_id: agent_id
    } do
      base = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      since = DateTime.add(base, -200, :second)

      # A keyed slot whose inserted_at PREDATES `since` but whose updated_at is the
      # MOST RECENT touch of all — it matches the GREATEST(...) > since filter.
      {:ok, slot} =
        Coordination.create_post(tenant.id, project.id, agent_id, %{"body" => "slot"})

      {:ok, _} =
        slot
        |> Ecto.Changeset.change(
          inserted_at: DateTime.add(base, -300, :second),
          updated_at: DateTime.add(base, -10, :second)
        )
        |> AdminRepo.update()

      # Two ordinary posts inserted AFTER `since` but BEFORE the slot's touch.
      seed_post(tenant, project, agent_id, "p1", DateTime.add(base, -100, :second))
      seed_post(tenant, project, agent_id, "p2", DateTime.add(base, -50, :second))

      # limit 2 with 3 matching rows: under a plain inserted_at DESC order the slot
      # (stale inserted_at) would rank last and be dropped; under the delta's
      # GREATEST DESC order it ranks FIRST (most-recent touch) and survives.
      bodies =
        tenant.id
        |> Coordination.recent(project.id, since: since, limit: 2)
        |> Enum.map(& &1.body)

      assert "slot" in bodies
      assert bodies == ["slot", "p2"]
    end

    test "recent_page reports has_more when the limit truncates, false otherwise", %{
      tenant: tenant,
      project: project,
      agent_id: agent_id
    } do
      base = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      for n <- 1..3 do
        seed_post(tenant, project, agent_id, "p#{n}", DateTime.add(base, -n, :second))
      end

      assert {truncated, true} = Coordination.recent_page(tenant.id, project.id, limit: 2)
      assert length(truncated) == 2

      assert {full, false} = Coordination.recent_page(tenant.id, project.id, limit: 5)
      assert length(full) == 3
    end

    test "clamp_recent_limit reflects the applied default (25) and cap (100)" do
      assert Coordination.clamp_recent_limit(nil) == 25
      assert Coordination.clamp_recent_limit(10) == 10
      assert Coordination.clamp_recent_limit(1000) == 100
      assert Coordination.clamp_recent_limit("1000") == 100
      assert Coordination.clamp_recent_limit("0") == 0
    end

    test "limit clamps to 100 even when more than 100 live posts exist", %{
      tenant: tenant,
      project: project,
      agent_id: agent_id
    } do
      for n <- 1..105 do
        {:ok, _} =
          Coordination.create_post(tenant.id, project.id, agent_id, %{"body" => "p#{n}"})
      end

      assert length(Coordination.recent(tenant.id, project.id, limit: 1000)) == 100
    end

    test "default limit (no opt) is 25", %{
      tenant: tenant,
      project: project,
      agent_id: agent_id
    } do
      for n <- 1..30 do
        {:ok, _} =
          Coordination.create_post(tenant.id, project.id, agent_id, %{"body" => "p#{n}"})
      end

      assert length(Coordination.recent(tenant.id, project.id)) == 25
    end
  end

  describe "per-session keyed slot" do
    test "two sessions with the same key do not clobber each other" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      agent_id = fixture(:agent, %{tenant_id: tenant.id}).id

      assert {:ok, post_a} =
               Coordination.create_post(tenant.id, project.id, agent_id, %{
                 "body" => "goal A",
                 "session_id" => "S1",
                 "key" => "session_goal"
               })

      assert {:ok, post_b} =
               Coordination.create_post(tenant.id, project.id, agent_id, %{
                 "body" => "goal B",
                 "session_id" => "S2",
                 "key" => "session_goal"
               })

      assert post_a.id != post_b.id
      posts = Coordination.recent(tenant.id, project.id)
      assert length(posts) == 2
    end
  end

  describe "post/3" do
    setup do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      agent_id = fixture(:agent, %{tenant_id: tenant.id}).id

      audit = [
        actor_type: "api_key",
        actor_id: Ecto.UUID.generate(),
        actor_label: "agent:worker-1"
      ]

      %{tenant: tenant, project: project, agent_id: agent_id, audit: audit}
    end

    test "a keyless post is created (201) and writes a 'posted' audit row", ctx do
      %{tenant: tenant, project: project, agent_id: agent_id, audit: audit} = ctx

      assert {:ok, post, :created} =
               Coordination.post(tenant.id, agent_id, %{
                 project_id: project.id,
                 body: "pushed PR #107",
                 audit: audit
               })

      assert post.tenant_id == tenant.id
      assert post.agent_id == agent_id

      expected = DateTime.add(DateTime.utc_now(), Coordination.retention_days() * 86_400, :second)
      assert_in_delta DateTime.to_unix(post.expires_at), DateTime.to_unix(expected), 120

      entry = one_audit_entry(tenant.id, post.id)
      assert entry.action == "posted"
      assert entry.entity_type == "channel_post"
      assert entry.actor_label == "agent:worker-1"
    end

    test "a repeat keyed post from the same session upserts (200), same id, 'upserted' audit",
         ctx do
      %{tenant: tenant, project: project, agent_id: agent_id, audit: audit} = ctx

      base = %{project_id: project.id, session_id: "S1", key: "session_goal", audit: audit}

      assert {:ok, first, :created} =
               Coordination.post(tenant.id, agent_id, Map.put(base, :body, "v1"))

      assert {:ok, second, :updated} =
               Coordination.post(tenant.id, agent_id, Map.put(base, :body, "v2"))

      assert second.id == first.id
      assert second.body == "v2"

      # exactly one row for the slot
      assert AdminRepo.aggregate(
               from(p in ChannelPost, where: p.project_id == ^project.id),
               :count,
               :id
             ) == 1

      # Append-only audit chain: the same slot id now carries "posted" (create)
      # then "upserted" (the in-place refresh).
      assert audit_actions(tenant.id, second.id) == ["posted", "upserted"]
    end

    test "a different session's same key is a distinct row (no cross-session clobber)", ctx do
      %{tenant: tenant, project: project, agent_id: agent_id, audit: audit} = ctx

      assert {:ok, s1, :created} =
               Coordination.post(tenant.id, agent_id, %{
                 project_id: project.id,
                 session_id: "S1",
                 key: "session_goal",
                 body: "v1",
                 audit: audit
               })

      assert {:ok, s2, :created} =
               Coordination.post(tenant.id, agent_id, %{
                 project_id: project.id,
                 session_id: "S2",
                 key: "session_goal",
                 body: "other",
                 audit: audit
               })

      assert s1.id != s2.id
    end

    test "a missing project returns {:error, :not_found} and writes nothing", ctx do
      %{tenant: tenant, agent_id: agent_id, audit: audit} = ctx

      assert {:error, :not_found} =
               Coordination.post(tenant.id, agent_id, %{
                 project_id: Ecto.UUID.generate(),
                 body: "x",
                 audit: audit
               })

      assert AdminRepo.aggregate(ChannelPost, :count, :id) == 0
    end

    test "a cross-tenant project returns {:error, :not_found} (same as missing)", ctx do
      %{tenant: tenant, agent_id: agent_id, audit: audit} = ctx
      other = fixture(:tenant)
      foreign = fixture(:project, %{tenant_id: other.id})

      assert {:error, :not_found} =
               Coordination.post(tenant.id, agent_id, %{
                 project_id: foreign.id,
                 body: "x",
                 audit: audit
               })
    end

    test "a foreign-tenant agent_id returns {:error, :agent_not_found}, distinct from the project error",
         ctx do
      %{tenant: tenant, project: project, audit: audit} = ctx
      other = fixture(:tenant)
      foreign_agent = fixture(:agent, %{tenant_id: other.id}).id

      # A valid project but an agent that belongs to another tenant: the ownership
      # guard is restored (defense-in-depth — the agent FKs are non-composite) and
      # maps to a DISTINCT error so the endpoint attributes an identity fault, not a
      # cross-tenant project probe.
      assert {:error, :agent_not_found} =
               Coordination.post(tenant.id, foreign_agent, %{
                 project_id: project.id,
                 body: "x",
                 audit: audit
               })

      assert AdminRepo.aggregate(ChannelPost, :count, :id) == 0

      assert AdminRepo.aggregate(
               from(a in AuditLog, where: a.entity_type == "channel_post"),
               :count,
               :id
             ) == 0
    end

    test "the created/updated outcome is derived from the persisted row, not a pre-transaction probe",
         ctx do
      %{tenant: tenant, project: project, agent_id: agent_id, audit: audit} = ctx

      # Pre-seed the keyed slot directly, then post/3 the SAME slot: the outcome
      # must reflect the row that actually persists (an in-place update via
      # ON CONFLICT), read from the returned row's timestamps rather than a
      # pre-transaction existence check that a concurrent write or TTL sweep could
      # invalidate between the read and the insert.
      assert {:ok, seed} =
               Coordination.create_post(tenant.id, project.id, agent_id, %{
                 "body" => "seed",
                 "session_id" => "S1",
                 "key" => "session_goal"
               })

      assert {:ok, post, :updated} =
               Coordination.post(tenant.id, agent_id, %{
                 project_id: project.id,
                 session_id: "S1",
                 key: "session_goal",
                 body: "v2",
                 audit: audit
               })

      assert post.id == seed.id
      assert post.body == "v2"
      assert audit_actions(tenant.id, post.id) == ["upserted"]
    end

    test "a missing body returns {:error, changeset} and writes no post or audit row", ctx do
      %{tenant: tenant, project: project, agent_id: agent_id, audit: audit} = ctx

      assert {:error, %Ecto.Changeset{} = changeset} =
               Coordination.post(tenant.id, agent_id, %{
                 project_id: project.id,
                 audit: audit
               })

      refute changeset.valid?
      assert AdminRepo.aggregate(ChannelPost, :count, :id) == 0

      assert AdminRepo.aggregate(
               from(a in AuditLog, where: a.entity_type == "channel_post"),
               :count,
               :id
             ) == 0
    end
  end

  describe "delete_post/3" do
    setup do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      agent_id = fixture(:agent, %{tenant_id: tenant.id}).id

      audit = [
        actor_type: "api_key",
        actor_id: Ecto.UUID.generate(),
        actor_label: "agent:deleter-1"
      ]

      %{tenant: tenant, project: project, agent_id: agent_id, audit: audit}
    end

    test "deletes a post in the tenant, removes it from recent, writes a 'deleted' audit row (TC-39.7.1)",
         ctx do
      %{tenant: tenant, project: project, agent_id: agent_id, audit: audit} = ctx

      {:ok, post} =
        Coordination.create_post(tenant.id, project.id, agent_id, %{"body" => "oops, a secret"})

      assert {:ok, deleted} = Coordination.delete_post(tenant.id, agent_id, post.id, audit)
      assert deleted.id == post.id

      # Row is gone.
      assert is_nil(AdminRepo.get(ChannelPost, post.id))
      refute Enum.any?(Coordination.recent(tenant.id, project.id), &(&1.id == post.id))

      # Audit trail survives the hard delete.
      entry = one_audit_entry(tenant.id, post.id)
      assert entry.action == "deleted"
      assert entry.entity_type == "channel_post"
      assert entry.actor_label == "agent:deleter-1"
      assert entry.metadata["deleted_post_agent_id"] == agent_id
    end

    test "any agent B in the same tenant may delete agent A's post; audit actor is B (TC-39.7.2)",
         ctx do
      %{tenant: tenant, project: project, agent_id: agent_a} = ctx
      agent_b = fixture(:agent, %{tenant_id: tenant.id}).id

      {:ok, post} =
        Coordination.create_post(tenant.id, project.id, agent_a, %{"body" => "from A"})

      audit_b = [
        actor_type: "api_key",
        actor_id: Ecto.UUID.generate(),
        actor_label: "agent:agent-b"
      ]

      assert {:ok, _deleted} = Coordination.delete_post(tenant.id, agent_b, post.id, audit_b)
      assert is_nil(AdminRepo.get(ChannelPost, post.id))

      entry = one_audit_entry(tenant.id, post.id)
      assert entry.action == "deleted"
      # The DELETING agent (B) is the audit actor — distinct from the author (A).
      assert entry.actor_label == "agent:agent-b"
      assert entry.metadata["deleted_post_agent_id"] == agent_a
      assert entry.metadata["deleted_by_agent_id"] == agent_b
    end

    test "a cross-tenant post id returns {:error, :not_found} and the foreign row still exists (TC-39.7.3)",
         ctx do
      %{tenant: tenant, agent_id: agent_id, audit: audit} = ctx
      other = fixture(:tenant)
      other_project = fixture(:project, %{tenant_id: other.id})
      other_agent = fixture(:agent, %{tenant_id: other.id}).id

      {:ok, foreign_post} =
        Coordination.create_post(other.id, other_project.id, other_agent, %{"body" => "theirs"})

      assert {:error, :not_found} =
               Coordination.delete_post(tenant.id, agent_id, foreign_post.id, audit)

      # The other tenant's post is untouched.
      assert %ChannelPost{} = AdminRepo.get(ChannelPost, foreign_post.id)
    end

    test "a nonexistent random UUID returns {:error, :not_found} (TC-39.7.4)", ctx do
      %{tenant: tenant, agent_id: agent_id, audit: audit} = ctx

      assert {:error, :not_found} =
               Coordination.delete_post(tenant.id, agent_id, Ecto.UUID.generate(), audit)
    end

    test "a malformed (non-UUID) post id returns {:error, :not_found}, never a CastError", ctx do
      %{tenant: tenant, agent_id: agent_id, audit: audit} = ctx

      assert {:error, :not_found} =
               Coordination.delete_post(tenant.id, agent_id, "not-a-uuid", audit)
    end

    test "tenant isolation: deleting with the wrong tenant_id does not remove the row", ctx do
      %{tenant: tenant, project: project, agent_id: agent_id, audit: audit} = ctx
      other = fixture(:tenant)

      {:ok, post} =
        Coordination.create_post(tenant.id, project.id, agent_id, %{"body" => "mine"})

      # Same post id, but scoped to a different tenant → not found, row intact.
      assert {:error, :not_found} =
               Coordination.delete_post(other.id, agent_id, post.id, audit)

      assert %ChannelPost{} = AdminRepo.get(ChannelPost, post.id)
    end

    test "deleting an already-deleted post is an idempotent {:error, :not_found}, never a raise (stale-delete race)",
         ctx do
      %{tenant: tenant, project: project, agent_id: agent_id, audit: audit} = ctx

      {:ok, post} =
        Coordination.create_post(tenant.id, project.id, agent_id, %{"body" => "race"})

      assert {:ok, _deleted} = Coordination.delete_post(tenant.id, agent_id, post.id, audit)

      # The fleet-wide "whoever notices a leaked secret" model makes two agents
      # deleting the SAME post a first-class case. A second delete of the now-gone
      # row must be an idempotent 404 — never an Ecto.StaleEntryError/500. (This is
      # the caller-visible half of the concurrent race: run_delete/4's rescue
      # collapses a true TOCTOU stale DELETE to the identical outcome.)
      assert {:error, :not_found} =
               Coordination.delete_post(tenant.id, agent_id, post.id, audit)
    end

    test "an audit-step failure rolls back the delete and returns {:error, :audit_write_failed} (fail-safe, never a masking 404)",
         ctx do
      %{tenant: tenant, project: project, agent_id: agent_id} = ctx

      {:ok, post} =
        Coordination.create_post(tenant.id, project.id, agent_id, %{"body" => "keepme"})

      # Force the audit insert to fail: actor_type is a REQUIRED audit field, and an
      # explicit nil in the audit context overrides run_delete's "api_key" default,
      # yielding an invalid audit changeset — the {:error, :audit, changeset, _}
      # Multi branch. Because the delete shares the transaction, the post SURVIVES,
      # so the redact path must NOT report a masking 404 ("already gone") — it
      # surfaces a DISTINCT {:error, :audit_write_failed} the controller maps to a
      # 5xx so the agent retries. It must never CaseClauseError/leak a raw 500.
      bad_audit = [actor_type: nil, actor_id: Ecto.UUID.generate(), actor_label: "x"]

      assert {:error, :audit_write_failed} =
               Coordination.delete_post(tenant.id, agent_id, post.id, bad_audit)

      # Transaction rolled back: the post survives and no audit row was written.
      assert %ChannelPost{} = AdminRepo.get(ChannelPost, post.id)

      assert AdminRepo.aggregate(
               from(a in AuditLog,
                 where: a.entity_type == "channel_post" and a.entity_id == ^post.id
               ),
               :count,
               :id
             ) == 0
    end
  end

  defp one_audit_entry(tenant_id, entity_id) do
    AdminRepo.one!(
      from(a in AuditLog,
        where: a.tenant_id == ^tenant_id and a.entity_type == "channel_post",
        where: a.entity_id == ^entity_id
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
end
