defmodule Loopctl.CoordinationTest do
  use Loopctl.DataCase, async: true

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.Audit.AuditLog
  alias Loopctl.Coordination
  alias Loopctl.Coordination.ChannelPost
  alias Loopctl.Progress
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
      # persisted list survives a fresh read (RefsList.load round-trip). The LIST
      # read now returns bounded preview maps (US-40.D1), not %ChannelPost{} structs.
      assert [%{refs: ^refs}] = Coordination.recent(tenant.id, project.id)
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
      # And tenant_a sees its own post (as a bounded preview map, US-40.D1).
      assert [%{body_preview: "tenant A only", truncated: false}] =
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

      assert [%{body_preview: _}] = Coordination.recent(tenant.id, project.id, limit: "abc")
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

      bodies = tenant.id |> Coordination.recent(project.id) |> Enum.map(& &1.body_preview)
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
        tenant.id |> Coordination.recent(project.id, since: t2) |> Enum.map(& &1.body_preview)

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
        tenant.id |> Coordination.recent(project.id, since: since) |> Enum.map(& &1.body_preview)

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
        |> Enum.map(& &1.body_preview)

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
        |> Enum.map(& &1.body_preview)

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

      assert [%{body_preview: _}] =
               Coordination.recent(tenant.id, project.id, since: "not-a-date")
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
        |> Enum.map(& &1.body_preview)
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
        |> Enum.map(& &1.body_preview)

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

      assert {truncated, true, next_cursor} =
               Coordination.recent_page(tenant.id, project.id, limit: 2)

      assert length(truncated) == 2
      assert match?({%DateTime{}, seq} when is_integer(seq), next_cursor)

      assert {full, false, nil} = Coordination.recent_page(tenant.id, project.id, limit: 5)
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

  describe "recent_page/3 keyset cursor + commit-lag delta (US-40.C2)" do
    setup do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      agent_id = fixture(:agent, %{tenant_id: tenant.id}).id
      %{tenant: tenant, project: project, agent_id: agent_id}
    end

    # Follow next_cursor to exhaustion, returning the concatenated rows + page count.
    defp page_all(tenant_id, project_id, limit) do
      pages =
        Stream.unfold(:start, fn
          :done ->
            nil

          state ->
            cursor = if state == :start, do: nil, else: state

            {page, _has_more, next} =
              Coordination.recent_page(tenant_id, project_id, limit: limit, cursor: cursor)

            {page, if(next, do: next, else: :done)}
        end)
        |> Enum.to_list()

      {Enum.concat(pages), length(pages)}
    end

    # TC-1
    test "cursor pages the full live set to exhaustion with no gaps or dups", %{
      tenant: tenant,
      project: project,
      agent_id: agent_id
    } do
      for n <- 1..250 do
        {:ok, _} =
          Coordination.create_post(tenant.id, project.id, agent_id, %{"body" => "p#{n}"})
      end

      {rows, page_count} = page_all(tenant.id, project.id, 100)

      ids = Enum.map(rows, & &1.id)
      assert length(ids) == 250, "expected all 250 posts seen exactly once"
      assert length(Enum.uniq(ids)) == 250, "no dups across pages"
      assert page_count == 3, "100 + 100 + 50 → 3 pages"

      # Deterministic newest-first ordering keyed on the monotonic seq: strictly
      # descending, total order even across same-microsecond inserted_at ties.
      seqs = Enum.map(rows, & &1.seq)
      assert seqs == Enum.sort(seqs, :desc)
      assert length(Enum.uniq(seqs)) == 250

      # Final page exhausts history: next_cursor is null.
      last_page_cursor =
        Stream.iterate(nil, fn c ->
          {_p, _hm, next} =
            Coordination.recent_page(tenant.id, project.id, limit: 100, cursor: c)

          next
        end)
        |> Enum.take(4)
        |> List.last()

      assert is_nil(last_page_cursor)
    end

    # TC-2
    test "rows sharing inserted_at order by seq DESC deterministically across runs", %{
      tenant: tenant,
      project: project,
      agent_id: agent_id
    } do
      ts = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      # seq is assigned at create time in order a < b < c; all three share inserted_at.
      for body <- ["a", "b", "c"] do
        seed_post(tenant, project, agent_id, body, ts)
      end

      for _ <- 1..5 do
        bodies = tenant.id |> Coordination.recent(project.id) |> Enum.map(& &1.body_preview)
        assert bodies == ["c", "b", "a"]
      end
    end

    # TC-3
    test "commit-lag look-back re-scans a late-committing earlier row (not dropped)", %{
      tenant: tenant,
      project: project,
      agent_id: agent_id
    } do
      watermark = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      # B is the row the reader already saw, AT the watermark.
      seed_post(tenant, project, agent_id, "B_seen", watermark)

      # A has an EARLIER inserted_at but (simulating a pre-commit-assigned timestamp
      # whose txn committed AFTER B) is only now visible — WITHIN the epsilon window.
      seed_post(tenant, project, agent_id, "A_late", DateTime.add(watermark, -2, :second))

      # A row older than the epsilon window must NOT be pulled in (bounded look-back,
      # not "return everything before the watermark").
      seed_post(tenant, project, agent_id, "far_old", DateTime.add(watermark, -60, :second))

      bodies =
        tenant.id
        |> Coordination.recent(project.id, since: watermark)
        |> Enum.map(& &1.body_preview)

      # Without the look-back, A_late (GREATEST = watermark-2s) would NOT satisfy
      # `> watermark` and would be lost forever. With epsilon it is re-delivered.
      assert "A_late" in bodies
      refute "far_old" in bodies
    end

    # TC-6
    test "an upserted slot after `since` surfaces (GREATEST) and is not dropped by limit", %{
      tenant: tenant,
      project: project,
      agent_id: agent_id
    } do
      base = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      since = DateTime.add(base, -200, :second)

      {:ok, slot} =
        Coordination.create_post(tenant.id, project.id, agent_id, %{"body" => "slot"})

      {:ok, _} =
        slot
        |> Ecto.Changeset.change(
          inserted_at: DateTime.add(base, -300, :second),
          updated_at: DateTime.add(base, -10, :second)
        )
        |> AdminRepo.update()

      seed_post(tenant, project, agent_id, "p1", DateTime.add(base, -100, :second))
      seed_post(tenant, project, agent_id, "p2", DateTime.add(base, -50, :second))

      {rows, has_more, next_cursor} =
        Coordination.recent_page(tenant.id, project.id, since: since, limit: 2)

      bodies = Enum.map(rows, & &1.body_preview)
      assert bodies == ["slot", "p2"]
      assert has_more
      # Delta mode does not emit a keyset cursor (paging is the consumer advancing
      # `since`); the keyset walks inserted_at, GREATEST ordering is a delta concept.
      assert is_nil(next_cursor)
    end

    test "a cursor takes precedence over `since` (the two reads are not unified)", %{
      tenant: tenant,
      project: project,
      agent_id: agent_id
    } do
      base = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      for n <- 1..5 do
        seed_post(tenant, project, agent_id, "p#{n}", DateTime.add(base, -n * 10, :second))
      end

      {first_page, true, cursor} = Coordination.recent_page(tenant.id, project.id, limit: 2)
      assert length(first_page) == 2

      # Pass BOTH a cursor and a `since` that alone would filter everything out. The
      # cursor wins → history walk continues; `since` is ignored.
      future = DateTime.add(base, 3600, :second)

      {second_page, _hm, _next} =
        Coordination.recent_page(tenant.id, project.id, limit: 2, cursor: cursor, since: future)

      first_ids = MapSet.new(first_page, & &1.id)
      assert Enum.all?(second_page, &(&1.id not in first_ids))
      assert length(second_page) == 2
    end

    # TC-4 (also covered by the D1 preview describe) — the cursor read returns a
    # bounded preview, never the full body.
    test "cursor read returns a bounded body_preview + truncated, never the full body", %{
      tenant: tenant,
      project: project,
      agent_id: agent_id
    } do
      big = String.duplicate("x", 16_384)
      {:ok, _} = Coordination.create_post(tenant.id, project.id, agent_id, %{"body" => big})

      {[row], _hm, _next} = Coordination.recent_page(tenant.id, project.id, limit: 10)

      assert byte_size(row.body_preview) <= Coordination.preview_bytes()
      assert row.truncated
      refute Map.has_key?(row, :body)
    end

    test "tenant isolation: paging tenant B cannot see tenant A's channel", %{
      tenant: tenant_a,
      project: project_a,
      agent_id: agent_a
    } do
      for n <- 1..3 do
        {:ok, _} =
          Coordination.create_post(tenant_a.id, project_a.id, agent_a, %{"body" => "a#{n}"})
      end

      tenant_b = fixture(:tenant)

      # Same project_id, different tenant → the explicit tenant filter excludes all
      # rows; the cursor path is no exception.
      assert {[], false, nil} =
               Coordination.recent_page(tenant_b.id, project_a.id, limit: 100)
    end

    # TRUNCATION-DRAIN RULE (Finding 1): a delta window larger than :limit truncates
    # the OLDEST-touched matching rows (delta orders GREATEST desc). Blindly advancing
    # the `since` watermark to the newest row would step PAST those older rows forever
    # (a lost-write gap). This proves the documented recovery affordance: the truncated
    # older row IS recoverable by DRAINING the backlog via the history cursor read.
    test "delta truncation: the dropped OLDEST row is recoverable via the history cursor drain",
         %{tenant: tenant, project: project, agent_id: agent_id} do
      base = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      since = DateTime.add(base, -200, :second)

      p_old = seed_post(tenant, project, agent_id, "p_old", DateTime.add(base, -150, :second))
      _p_mid = seed_post(tenant, project, agent_id, "p_mid", DateTime.add(base, -100, :second))
      _p_new = seed_post(tenant, project, agent_id, "p_new", DateTime.add(base, -50, :second))

      # Delta read at limit 2 over a 3-row window: newest two kept, p_old truncated.
      {delta_rows, has_more, next_cursor} =
        Coordination.recent_page(tenant.id, project.id, since: since, limit: 2)

      assert has_more
      assert is_nil(next_cursor)
      delta_bodies = Enum.map(delta_rows, & &1.body_preview)
      assert delta_bodies == ["p_new", "p_mid"]
      refute "p_old" in delta_bodies

      # The lost-write gap: naively advancing the watermark to the newest row and
      # re-reading the delta would NOT surface p_old (it sorts below the new watermark,
      # even after the epsilon look-back). This is what the drain rule exists to avoid.
      advanced = DateTime.add(base, -50, :second)

      {advanced_rows, _hm, _nc} =
        Coordination.recent_page(tenant.id, project.id, since: advanced, limit: 100)

      refute "p_old" in Enum.map(advanced_rows, & &1.body_preview)

      # DRAIN affordance: the history cursor read (walked to exhaustion) returns EVERY
      # live row, including the truncated p_old — so a burst larger than the cap loses
      # nothing when the consumer drains before advancing its watermark.
      {drained, _pages} = page_all(tenant.id, project.id, 2)
      drained_ids = Enum.map(drained, & &1.id)
      assert p_old.id in drained_ids
      assert length(drained_ids) == 3
      assert length(Enum.uniq(drained_ids)) == 3
    end

    # Finding 2: the history keyset walk pages the already-COMMITTED snapshot without
    # gaps or dups, but does NOT claim to also return a row that COMMITS mid-walk above
    # the emitted cursor frontier — that new-row completeness is the DELTA read's job.
    # This is the covering test for the narrowed AC-40.C2.5 / recent_page/3 claim.
    test "history walk covers committed rows; a mid-walk insert is owned by the delta read, not the backward walk",
         %{tenant: tenant, project: project, agent_id: agent_id} do
      base = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      committed =
        for n <- 1..5 do
          seed_post(tenant, project, agent_id, "c#{n}", DateTime.add(base, -n * 10, :second))
        end

      committed_ids = MapSet.new(committed, & &1.id)

      # First history page (frontier established at the 2nd row's cursor).
      {first_page, true, cursor} = Coordination.recent_page(tenant.id, project.id, limit: 2)
      assert length(first_page) == 2

      # A brand-new post COMMITS mid-walk. create_post stamps `now`, so its
      # (inserted_at, seq) is ABOVE the already-emitted cursor frontier.
      watermark = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      {:ok, late} = Coordination.create_post(tenant.id, project.id, agent_id, %{"body" => "late"})

      # Continue the backward walk from the mid-walk cursor to exhaustion.
      continuation =
        Stream.unfold(cursor, fn
          nil ->
            nil

          c ->
            {page, _hm, next} =
              Coordination.recent_page(tenant.id, project.id, limit: 2, cursor: c)

            {page, next}
        end)
        |> Enum.to_list()
        |> Enum.concat()

      walked_ids = MapSet.new(first_page ++ continuation, & &1.id)

      # Committed-snapshot completeness: every row that existed when the walk started
      # is returned exactly once across the pages.
      assert MapSet.subset?(committed_ids, walked_ids)
      walked_list = Enum.map(first_page ++ continuation, & &1.id)
      assert length(walked_list) == length(Enum.uniq(walked_list)), "no dups across pages"

      # The mid-walk insert is ABOVE the frontier — the backward walk does NOT revisit
      # it. This is the standard, deliberate keyset property (not a lost write).
      refute late.id in walked_ids

      # New-row completeness is owned by the DELTA read: a watermark just before the
      # insert surfaces the late row that the backward walk skipped.
      {delta, _hm, _nc} =
        Coordination.recent_page(tenant.id, project.id, since: watermark, limit: 100)

      assert late.id in Enum.map(delta, & &1.id)
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

  describe "bounded preview projection (US-40.D1)" do
    test "a small body is returned verbatim in body_preview with truncated=false" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      agent_id = fixture(:agent, %{tenant_id: tenant.id}).id

      {:ok, _} =
        Coordination.create_post(tenant.id, project.id, agent_id, %{"body" => "short body"})

      assert [row] = Coordination.recent(tenant.id, project.id)
      assert row.body_preview == "short body"
      assert row.truncated == false
      # The read model carries no full `body` key — only the bounded preview.
      refute Map.has_key?(row, :body)
    end

    test "a 16KB body is truncated to <= preview_bytes with truncated=true (prefix of the body)" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      agent_id = fixture(:agent, %{tenant_id: tenant.id}).id

      big = String.duplicate("a", 16_384)
      {:ok, _} = Coordination.create_post(tenant.id, project.id, agent_id, %{"body" => big})

      assert [row] = Coordination.recent(tenant.id, project.id)
      assert byte_size(row.body_preview) <= Coordination.preview_bytes()
      assert row.truncated == true
      assert String.starts_with?(big, row.body_preview)
    end

    test "a body of exactly preview_bytes is not truncated" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      agent_id = fixture(:agent, %{tenant_id: tenant.id}).id

      n = Coordination.preview_bytes()
      body = String.duplicate("b", n)
      {:ok, _} = Coordination.create_post(tenant.id, project.id, agent_id, %{"body" => body})

      assert [row] = Coordination.recent(tenant.id, project.id)
      assert row.body_preview == body
      assert byte_size(row.body_preview) == n
      assert row.truncated == false
    end

    test "a body one byte over preview_bytes is truncated to exactly preview_bytes" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      agent_id = fixture(:agent, %{tenant_id: tenant.id}).id

      n = Coordination.preview_bytes()
      body = String.duplicate("c", n + 1)
      {:ok, _} = Coordination.create_post(tenant.id, project.id, agent_id, %{"body" => body})

      assert [row] = Coordination.recent(tenant.id, project.id)
      assert byte_size(row.body_preview) == n
      assert row.truncated == true
    end

    test "a multibyte body truncates on a codepoint boundary (valid UTF-8, valid JSON)" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      agent_id = fixture(:agent, %{tenant_id: tenant.id}).id

      # 3-byte codepoints so the byte cut at preview_bytes (512) lands MID-codepoint
      # (512 = 170*3 + 2), forcing utf8_prefix/2's repair loop to drop the split
      # trailing bytes. 300 chars = 900 bytes: over the 512-byte preview bound,
      # within the 16KB body cap.
      body = String.duplicate("€", 300)
      {:ok, _} = Coordination.create_post(tenant.id, project.id, agent_id, %{"body" => body})

      assert [row] = Coordination.recent(tenant.id, project.id)
      # The repair loop dropped the 2 split trailing bytes: 512 is not a multiple
      # of 3, so the valid prefix is STRICTLY under the bound (510 = 170*3), which
      # only holds if utf8_prefix/2's else-branch actually ran.
      assert byte_size(row.body_preview) < Coordination.preview_bytes()
      assert byte_size(row.body_preview) == 510
      assert row.truncated == true
      assert String.valid?(row.body_preview)
      # It is a genuine prefix of the original body (no codepoint mangled).
      assert String.starts_with?(body, row.body_preview)
      # Encodes cleanly (a split codepoint would break Jason).
      assert {:ok, _} = Jason.encode(row.body_preview)
    end
  end

  describe "get_post/2 (US-40.D1)" do
    test "an owned post returns {:ok, post} with the FULL body" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      agent_id = fixture(:agent, %{tenant_id: tenant.id}).id

      big = String.duplicate("z", 16_384)

      {:ok, created} =
        Coordination.create_post(tenant.id, project.id, agent_id, %{"body" => big})

      assert {:ok, %ChannelPost{} = post} = Coordination.get_post(tenant.id, created.id)
      assert post.id == created.id
      # The full 16KB body is returned (not a bounded preview).
      assert post.body == big
      assert byte_size(post.body) == 16_384
    end

    test "a post in another tenant returns {:error, :not_found} (no cross-tenant oracle)" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      project_b = fixture(:project, %{tenant_id: tenant_b.id})
      agent_b = fixture(:agent, %{tenant_id: tenant_b.id}).id

      {:ok, foreign} =
        Coordination.create_post(tenant_b.id, project_b.id, agent_b, %{"body" => "theirs"})

      assert {:error, :not_found} = Coordination.get_post(tenant_a.id, foreign.id)
      # And a nonexistent id in tenant_a returns the identical error (byte-identical
      # 404 at the HTTP boundary — no existence oracle).
      assert {:error, :not_found} = Coordination.get_post(tenant_a.id, Ecto.UUID.generate())
    end

    test "a nonexistent id returns {:error, :not_found}" do
      tenant = fixture(:tenant)
      assert {:error, :not_found} = Coordination.get_post(tenant.id, Ecto.UUID.generate())
    end

    test "a malformed (non-UUID) post_id returns {:error, :not_found}, not a CastError" do
      tenant = fixture(:tenant)
      assert {:error, :not_found} = Coordination.get_post(tenant.id, "not-a-uuid")
    end

    test "a malformed (non-UUID) tenant_id returns {:error, :not_found}" do
      project_tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: project_tenant.id})
      agent_id = fixture(:agent, %{tenant_id: project_tenant.id}).id

      {:ok, post} =
        Coordination.create_post(project_tenant.id, project.id, agent_id, %{"body" => "hi"})

      assert {:error, :not_found} = Coordination.get_post("not-a-uuid", post.id)
    end
  end

  describe "post/4" do
    setup do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      agent_id = fixture(:agent, %{tenant_id: tenant.id}).id

      # US-40.D3: writes are project-scoped by membership. Make the agent a
      # writable member of the project by assigning it a story there, so these
      # upsert/addressing/audit tests exercise the happy path through the new gate.
      fixture(:story, %{
        tenant_id: tenant.id,
        project_id: project.id,
        assigned_agent_id: agent_id,
        agent_status: :assigned
      })

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
               Coordination.post(tenant.id, agent_id, :agent, %{
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
               Coordination.post(tenant.id, agent_id, :agent, Map.put(base, :body, "v1"))

      assert {:ok, second, :updated} =
               Coordination.post(tenant.id, agent_id, :agent, Map.put(base, :body, "v2"))

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

    test "a keyed re-post refreshes advisory addressing (to_host/to_capability) in place", ctx do
      %{tenant: tenant, project: project, agent_id: agent_id, audit: audit} = ctx

      # to_host/to_capability are caller-variable advisory PAYLOAD, not slot-identity
      # metadata — so a keyed re-post of the same working-state slot must be able to
      # re-address it (US-40.A5), otherwise 40.C1 directed discovery reads the stale
      # FIRST-set target on a handoff refresh. A SUPPLIED (non-nil) value overrides
      # via COALESCE(EXCLUDED, existing) on the upsert.
      base = %{project_id: project.id, session_id: "S1", key: "handoff:fly", audit: audit}

      assert {:ok, first, :created} =
               Coordination.post(
                 tenant.id,
                 agent_id,
                 :agent,
                 base
                 |> Map.put(:body, "broadcast state")
                 |> Map.put(:to_host, "mac-mini")
               )

      assert first.to_host == "mac-mini"
      assert is_nil(first.to_capability)

      # Re-post the SAME slot: change to_host AND newly add to_capability (promote a
      # host-directed slot to a capability-directed one).
      assert {:ok, second, :updated} =
               Coordination.post(
                 tenant.id,
                 agent_id,
                 :agent,
                 base
                 |> Map.put(:body, "directed handoff")
                 |> Map.put(:to_host, "beelink")
                 |> Map.put(:to_capability, "fly-auth")
               )

      assert second.id == first.id
      assert second.to_host == "beelink"
      assert second.to_capability == "fly-auth"

      # The addressing on the PERSISTED row reflects the refresh (not a phantom on
      # the returned struct only).
      reloaded = AdminRepo.get!(ChannelPost, second.id)
      assert reloaded.to_host == "beelink"
      assert reloaded.to_capability == "fly-auth"

      assert AdminRepo.aggregate(
               from(p in ChannelPost, where: p.project_id == ^project.id),
               :count,
               :id
             ) == 1
    end

    test "a keyed re-post that OMITS addressing preserves it (no silent demote to broadcast)",
         ctx do
      %{tenant: tenant, project: project, agent_id: agent_id, audit: audit} = ctx

      # The directed-handoff footgun this story must NOT have: a session posts a
      # directed slot, then re-posts the SAME slot to update only body / extend TTL
      # and OMITS addressing (the default through the controller + MCP proxy, which
      # send to_host/to_capability only when present). Addressing is preserve-on-omit
      # (COALESCE(EXCLUDED, existing)), so the omitted target is KEPT — the slot stays
      # directed and remains visible to 40.C1 directed discovery, rather than being
      # silently NULL-wiped to a broadcast.
      base = %{project_id: project.id, session_id: "S1", key: "handoff:fly", audit: audit}

      assert {:ok, first, :created} =
               Coordination.post(
                 tenant.id,
                 agent_id,
                 :agent,
                 base
                 |> Map.put(:body, "directed handoff")
                 |> Map.put(:to_host, "beelink")
                 |> Map.put(:to_capability, "fly-auth")
               )

      assert first.to_host == "beelink"
      assert first.to_capability == "fly-auth"

      # Re-post the SAME slot updating ONLY body — no to_host/to_capability keys.
      assert {:ok, second, :updated} =
               Coordination.post(
                 tenant.id,
                 agent_id,
                 :agent,
                 base |> Map.put(:body, "still working, refreshed")
               )

      assert second.id == first.id
      assert second.body == "still working, refreshed"

      # Addressing survived the body-only refresh (both the returned struct and the
      # persisted row) — the slot is still directed, not demoted to broadcast.
      assert second.to_host == "beelink"
      assert second.to_capability == "fly-auth"

      reloaded = AdminRepo.get!(ChannelPost, second.id)
      assert reloaded.to_host == "beelink"
      assert reloaded.to_capability == "fly-auth"

      # A subsequent re-post CAN still change one target while omitting the other:
      # the supplied to_host overrides, the omitted to_capability is preserved.
      assert {:ok, third, :updated} =
               Coordination.post(
                 tenant.id,
                 agent_id,
                 :agent,
                 base
                 |> Map.put(:body, "moved hosts")
                 |> Map.put(:to_host, "mac-mini")
               )

      assert third.to_host == "mac-mini"
      assert third.to_capability == "fly-auth"

      assert AdminRepo.aggregate(
               from(p in ChannelPost, where: p.project_id == ^project.id),
               :count,
               :id
             ) == 1
    end

    test "a different session's same key is a distinct row (no cross-session clobber)", ctx do
      %{tenant: tenant, project: project, agent_id: agent_id, audit: audit} = ctx

      assert {:ok, s1, :created} =
               Coordination.post(tenant.id, agent_id, :agent, %{
                 project_id: project.id,
                 session_id: "S1",
                 key: "session_goal",
                 body: "v1",
                 audit: audit
               })

      assert {:ok, s2, :created} =
               Coordination.post(tenant.id, agent_id, :agent, %{
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
               Coordination.post(tenant.id, agent_id, :agent, %{
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
               Coordination.post(tenant.id, agent_id, :agent, %{
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
               Coordination.post(tenant.id, foreign_agent, :agent, %{
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
               Coordination.post(tenant.id, agent_id, :agent, %{
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
               Coordination.post(tenant.id, agent_id, :agent, %{
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

  # US-454: the three defect fixes from the cross-machine handoff incident
  # (issue #454). Defect 1 — a session without CLAUDE_SESSION_ID could only
  # post keyless, so its handoffs were invisible to directed discovery and
  # unclaimable; the server now derives a handoff:<anchor> key from the body
  # and mints a surrogate session_id instead of 422ing, and TELLS the sender
  # via the provenance markers. Defect 3 — supersession is a real terminal
  # state (`superseded_by`), excluded from discovery, marked in the history
  # read. (Defect 2's see-everything discovery is covered in
  # directed_handoffs_test.exs.)
  describe "post/4 US-454 handoff rescue + supersession" do
    setup do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      agent_id = fixture(:agent, %{tenant_id: tenant.id}).id

      fixture(:story, %{
        tenant_id: tenant.id,
        project_id: project.id,
        assigned_agent_id: agent_id,
        agent_status: :assigned
      })

      %{tenant: tenant, project: project, agent_id: agent_id}
    end

    test "a keyless post whose body STARTS WITH a handoff anchor gets the key DERIVED (discoverable), marked key_source",
         ctx do
      %{tenant: tenant, project: project, agent_id: agent_id} = ctx

      assert {:ok, post, :created} =
               Coordination.post(tenant.id, agent_id, :agent, %{
                 project_id: project.id,
                 body: "handoff:pr#453-port-4030 — dev port moved, update .mcp.json"
               })

      assert post.key == "handoff:pr#453-port-4030"
      assert post.key_source == "derived_from_body"

      # And it is discoverable as a handoff — the exact failure of the incident.
      assert [row] = Coordination.directed_handoffs(tenant.id, project.id, %{})
      assert row.key == "handoff:pr#453-port-4030"
    end

    test "a keyless post with no handoff anchor stays keyless and unmarked", ctx do
      %{tenant: tenant, project: project, agent_id: agent_id} = ctx

      assert {:ok, post, :created} =
               Coordination.post(tenant.id, agent_id, :agent, %{
                 project_id: project.id,
                 body: "just a status update"
               })

      assert is_nil(post.key)
      assert is_nil(post.key_source)
    end

    test "a keyless post with a passing mention (not at start-of-body) stays keyless", ctx do
      %{tenant: tenant, project: project, agent_id: agent_id} = ctx

      assert {:ok, post, :created} =
               Coordination.post(tenant.id, agent_id, :agent, %{
                 project_id: project.id,
                 body: "done with handoff:repo#812, starting work on the next thing"
               })

      # The anchor is NOT at start-of-body, so derivation is skipped.
      assert is_nil(post.key)
      assert is_nil(post.key_source)
    end

    test "an explicit key always wins over a body anchor (no derivation)", ctx do
      %{tenant: tenant, project: project, agent_id: agent_id} = ctx

      assert {:ok, post, :created} =
               Coordination.post(tenant.id, agent_id, :agent, %{
                 project_id: project.id,
                 session_id: "S1",
                 key: "handoff:explicit",
                 body: "discussing handoff:other-anchor in passing"
               })

      assert post.key == "handoff:explicit"
      assert is_nil(post.key_source)
    end

    test "a keyed post WITHOUT session_id is rescued by a surrogate (no more 422), marked session_id_source",
         ctx do
      %{tenant: tenant, project: project, agent_id: agent_id} = ctx

      assert {:ok, post, :created} =
               Coordination.post(tenant.id, agent_id, :agent, %{
                 project_id: project.id,
                 key: "handoff:nosession",
                 body: "keyed but the proxy had no CLAUDE_SESSION_ID"
               })

      assert post.session_id =~ ~r/^srvgen-/
      assert post.session_id_source == "server_surrogate"

      # Discoverable + the claim ref (= key) exists, so it is claimable.
      assert [row] = Coordination.directed_handoffs(tenant.id, project.id, %{})
      assert row.key == "handoff:nosession"
    end

    test "a keyed post WITH session_id keeps it (no surrogate, no marker)", ctx do
      %{tenant: tenant, project: project, agent_id: agent_id} = ctx

      assert {:ok, post, :created} =
               Coordination.post(tenant.id, agent_id, :agent, %{
                 project_id: project.id,
                 session_id: "real-session",
                 key: "handoff:withsession",
                 body: "normal keyed post"
               })

      assert post.session_id == "real-session"
      assert is_nil(post.session_id_source)
    end

    test "a HANDOFF-announcing body carrying a client idempotency token 422s LOUDLY (issue #454 fix 2)",
         ctx do
      %{tenant: tenant, project: project, agent_id: agent_id} = ctx

      # The body announces a handoff, so the key IS derived — and the derived
      # key + the client token trip the key/idempotency_key exclusion. A loud
      # 422 beats a silent drop: the client must choose an explicit key (the
      # keyed slot dedups its retry) or a token (keyless — and undiscoverable
      # by its own choice, told so by the error).
      assert {:error, %Ecto.Changeset{} = changeset} =
               Coordination.post(tenant.id, agent_id, :agent, %{
                 project_id: project.id,
                 idempotency_key: "retry-token-1",
                 body: "HANDOFF (handoff:with-token) — retried append"
               })

      assert %{idempotency_key: [_ | _]} = errors_on(changeset)
      assert AdminRepo.aggregate(ChannelPost, :count, :id) == 0
    end

    test "supersedes marks the target superseded_by in the same transaction; discovery excludes it",
         ctx do
      %{tenant: tenant, project: project, agent_id: agent_id} = ctx

      assert {:ok, stale, :created} =
               Coordination.post(tenant.id, agent_id, :agent, %{
                 project_id: project.id,
                 key: "handoff:old",
                 body: "pre-merge instructions"
               })

      assert {:ok, successor, :created} =
               Coordination.post(tenant.id, agent_id, :agent, %{
                 project_id: project.id,
                 key: "handoff:new",
                 body: "post-merge instructions",
                 supersedes: stale.id
               })

      reloaded = AdminRepo.get!(ChannelPost, stale.id)
      assert reloaded.superseded_by == successor.id

      # The stale handoff is retired from discovery (defect 3); the live one stays.
      assert [row] = Coordination.directed_handoffs(tenant.id, project.id, %{})
      assert row.key == "handoff:new"
    end

    test "the history read MARKS a superseded post with its successor id", ctx do
      %{tenant: tenant, project: project, agent_id: agent_id} = ctx

      assert {:ok, stale, :created} =
               Coordination.post(tenant.id, agent_id, :agent, %{
                 project_id: project.id,
                 body: "stale status"
               })

      assert {:ok, successor, :created} =
               Coordination.post(tenant.id, agent_id, :agent, %{
                 project_id: project.id,
                 body: "current status",
                 supersedes: stale.id
               })

      rows = Coordination.recent(tenant.id, project.id, limit: 10)
      stale_row = Enum.find(rows, &(&1.id == stale.id))
      assert stale_row.superseded_by == successor.id
    end

    test "supersedes on another agent's post is rejected (:agent role)", ctx do
      %{tenant: tenant, project: project, agent_id: agent_id} = ctx
      other_agent = fixture(:agent, %{tenant_id: tenant.id}).id

      # The other agent must be a writable MEMBER to post at all (US-40.D3).
      fixture(:story, %{
        tenant_id: tenant.id,
        project_id: project.id,
        assigned_agent_id: other_agent,
        agent_status: :assigned
      })

      assert {:ok, other_post, :created} =
               Coordination.post(tenant.id, other_agent, :agent, %{
                 project_id: project.id,
                 body: "someone else's post"
               })

      assert {:error, :supersede_target_not_found} =
               Coordination.post(tenant.id, agent_id, :agent, %{
                 project_id: project.id,
                 body: "trying to retire a peer's post",
                 supersedes: other_post.id
               })

      assert is_nil(AdminRepo.get!(ChannelPost, other_post.id).superseded_by)
    end

    test "an elevated role (>= :user) MAY supersede another agent's post (operator curation)",
         ctx do
      %{tenant: tenant, project: project, agent_id: agent_id} = ctx
      other_agent = fixture(:agent, %{tenant_id: tenant.id}).id

      fixture(:story, %{
        tenant_id: tenant.id,
        project_id: project.id,
        assigned_agent_id: other_agent,
        agent_status: :assigned
      })

      assert {:ok, other_post, :created} =
               Coordination.post(tenant.id, other_agent, :agent, %{
                 project_id: project.id,
                 body: "a mistaken post"
               })

      assert {:ok, successor, :created} =
               Coordination.post(tenant.id, agent_id, :user, %{
                 project_id: project.id,
                 body: "operator correction",
                 supersedes: other_post.id
               })

      assert AdminRepo.get!(ChannelPost, other_post.id).superseded_by == successor.id
    end

    test "supersedes a nonexistent or cross-project post returns :supersede_target_not_found",
         ctx do
      %{tenant: tenant, project: project, agent_id: agent_id} = ctx

      assert {:error, :supersede_target_not_found} =
               Coordination.post(tenant.id, agent_id, :agent, %{
                 project_id: project.id,
                 body: "superseding a ghost",
                 supersedes: Ecto.UUID.generate()
               })

      other_project = fixture(:project, %{tenant_id: tenant.id})

      # Membership on the OTHER channel too, so the post lands there.
      fixture(:story, %{
        tenant_id: tenant.id,
        project_id: other_project.id,
        assigned_agent_id: agent_id,
        agent_status: :assigned
      })

      assert {:ok, foreign, :created} =
               Coordination.post(tenant.id, agent_id, :agent, %{
                 project_id: other_project.id,
                 body: "post on another channel"
               })

      assert {:error, :supersede_target_not_found} =
               Coordination.post(tenant.id, agent_id, :agent, %{
                 project_id: project.id,
                 body: "cross-project supersede attempt",
                 supersedes: foreign.id
               })
    end

    test "supersedes a post in another tenant returns :supersede_target_not_found", ctx do
      %{tenant: tenant, project: project, agent_id: agent_id} = ctx
      tenant_b = fixture(:tenant)
      project_b = fixture(:project, %{tenant_id: tenant_b.id})
      agent_b = fixture(:agent, %{tenant_id: tenant_b.id}).id

      fixture(:story, %{
        tenant_id: tenant_b.id,
        project_id: project_b.id,
        assigned_agent_id: agent_b,
        agent_status: :assigned
      })

      assert {:ok, foreign_post, :created} =
               Coordination.post(tenant_b.id, agent_b, :agent, %{
                 project_id: project_b.id,
                 body: "post in tenant B"
               })

      assert {:error, :supersede_target_not_found} =
               Coordination.post(tenant.id, agent_id, :agent, %{
                 project_id: project.id,
                 body: "cross-tenant supersede attempt",
                 supersedes: foreign_post.id
               })

      assert is_nil(AdminRepo.get!(ChannelPost, foreign_post.id).superseded_by)
    end

    test "self-supersede via the keyed upsert path 422s (cannot supersede itself)", ctx do
      %{tenant: tenant, project: project, agent_id: agent_id} = ctx

      base = %{project_id: project.id, session_id: "S1", key: "handoff:self"}

      assert {:ok, first, :created} =
               Coordination.post(tenant.id, agent_id, :agent, Map.put(base, :body, "v1"))

      assert {:error, %Ecto.Changeset{} = changeset} =
               Coordination.post(
                 tenant.id,
                 agent_id,
                 :agent,
                 base |> Map.put(:body, "v2") |> Map.put(:supersedes, first.id)
               )

      assert %{superseded_by: [_ | _]} = errors_on(changeset)
      assert is_nil(AdminRepo.get!(ChannelPost, first.id).superseded_by)
    end
  end

  # US-40.B2: an OPTIONAL client idempotency token on the KEYLESS write path. A
  # keyless post is a pure append, so a retried or offline-reconciled /handoff
  # write would duplicate the row. With a token, a repeat write of the same
  # (tenant, project, agent, idempotency_key) returns the EXISTING post
  # (:deduplicated) instead of appending a duplicate — the same guarantee
  # knowledge_create gives. Absent, the write is exactly append-only (US-39.2).
  describe "post/4 keyless idempotency (US-40.B2)" do
    setup do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      agent_id = fixture(:agent, %{tenant_id: tenant.id}).id

      fixture(:story, %{
        tenant_id: tenant.id,
        project_id: project.id,
        assigned_agent_id: agent_id,
        agent_status: :assigned
      })

      audit = [
        actor_type: "api_key",
        actor_id: Ecto.UUID.generate(),
        actor_label: "agent:worker-1"
      ]

      %{tenant: tenant, project: project, agent_id: agent_id, audit: audit}
    end

    test "the idempotency partial index is scoped to KEYLESS rows (WHERE ... AND key IS NULL)" do
      # Storage-layer backstop for the keyless-only invariant (the changeset 422 in
      # `validate_key_idempotency_exclusion/1` is primary; this index is
      # defense-in-depth). Assert the APPLIED index predicate excludes keyed rows so
      # a future migration edit can't silently drop `AND key IS NULL` and re-open the
      # out-of-scope cross-session keyed-dedup hole — the exact regression the medium
      # review finding flagged. Also confirms the DB-under-test matches the
      # migration-as-written (guards against an in-place migration edit leaving a
      # stale index behind an already-applied version).
      indexdef =
        AdminRepo.query!(
          "SELECT indexdef FROM pg_indexes WHERE indexname = 'channel_posts_idempotency_uidx'"
        ).rows
        |> List.first()
        |> List.first()

      assert indexdef =~ "idempotency_key IS NOT NULL"
      assert indexdef =~ "key IS NULL"
    end

    test "TC-40.B2.2: a keyless write with an idempotency token dedups to the same row", ctx do
      %{tenant: tenant, project: project, agent_id: agent_id, audit: audit} = ctx

      base = %{
        project_id: project.id,
        body: "offline-reconciled handoff",
        idempotency_key: "abc",
        audit: audit
      }

      assert {:ok, first, :created} = Coordination.post(tenant.id, agent_id, :agent, base)

      # A repeat with the SAME token returns the EXISTING post, no new row.
      assert {:ok, second, :deduplicated} = Coordination.post(tenant.id, agent_id, :agent, base)

      assert second.id == first.id

      assert AdminRepo.aggregate(
               from(p in ChannelPost, where: p.project_id == ^project.id),
               :count,
               :id
             ) == 1

      # The dedup rolled back the transaction, so no second audit row was written.
      assert audit_actions(tenant.id, first.id) == ["posted"]
    end

    test "TC-40.B2.3: different agents, same token, no collision (scoped per-agent)", ctx do
      %{tenant: tenant, project: project, agent_id: agent_a, audit: audit} = ctx

      agent_b = fixture(:agent, %{tenant_id: tenant.id}).id

      fixture(:story, %{
        tenant_id: tenant.id,
        project_id: project.id,
        assigned_agent_id: agent_b,
        agent_status: :assigned
      })

      base = %{project_id: project.id, body: "shared token", idempotency_key: "abc", audit: audit}

      assert {:ok, post_a, :created} = Coordination.post(tenant.id, agent_a, :agent, base)
      assert {:ok, post_b, :created} = Coordination.post(tenant.id, agent_b, :agent, base)

      # Two DISTINCT posts — the token is scoped per (tenant, project, agent), so B's
      # write neither dedups nor collides with A's.
      refute post_a.id == post_b.id

      assert AdminRepo.aggregate(
               from(p in ChannelPost, where: p.project_id == ^project.id),
               :count,
               :id
             ) == 2
    end

    test "TC-40.B2.4: no token = append-only (two writes = two rows, unchanged)", ctx do
      %{tenant: tenant, project: project, agent_id: agent_id, audit: audit} = ctx

      base = %{project_id: project.id, body: "same body, no token", audit: audit}

      assert {:ok, first, :created} = Coordination.post(tenant.id, agent_id, :agent, base)
      assert {:ok, second, :created} = Coordination.post(tenant.id, agent_id, :agent, base)

      refute first.id == second.id

      assert AdminRepo.aggregate(
               from(p in ChannelPost, where: p.project_id == ^project.id),
               :count,
               :id
             ) == 2
    end

    test "tenant isolation: the same token in tenant A does not dedup a write in tenant B", ctx do
      %{tenant: tenant_a, project: project_a, agent_id: agent_a, audit: audit} = ctx

      tenant_b = fixture(:tenant)
      project_b = fixture(:project, %{tenant_id: tenant_b.id})
      agent_b = fixture(:agent, %{tenant_id: tenant_b.id}).id

      fixture(:story, %{
        tenant_id: tenant_b.id,
        project_id: project_b.id,
        assigned_agent_id: agent_b,
        agent_status: :assigned
      })

      assert {:ok, post_a, :created} =
               Coordination.post(tenant_a.id, agent_a, :agent, %{
                 project_id: project_a.id,
                 body: "tenant A",
                 idempotency_key: "shared-token",
                 audit: audit
               })

      # Tenant B, same token — a fresh create, never a cross-tenant dedup.
      assert {:ok, post_b, :created} =
               Coordination.post(tenant_b.id, agent_b, :agent, %{
                 project_id: project_b.id,
                 body: "tenant B",
                 idempotency_key: "shared-token",
                 audit: audit
               })

      refute post_a.id == post_b.id
      assert post_b.tenant_id == tenant_b.id
    end

    test "a blank/whitespace idempotency_key normalizes to nil (append-only, no dedup)", ctx do
      %{tenant: tenant, project: project, agent_id: agent_id, audit: audit} = ctx

      base = %{project_id: project.id, body: "blank token", idempotency_key: "   ", audit: audit}

      assert {:ok, first, :created} = Coordination.post(tenant.id, agent_id, :agent, base)
      assert is_nil(first.idempotency_key)

      # A second blank-token write appends (blank ⇒ nil ⇒ no idempotency dimension),
      # exactly like the no-token path — it does NOT collide on the partial index
      # (which is WHERE idempotency_key IS NOT NULL).
      assert {:ok, second, :created} = Coordination.post(tenant.id, agent_id, :agent, base)
      refute first.id == second.id
    end

    test "an over-length idempotency_key is a 422 changeset error, not a dedup", ctx do
      %{tenant: tenant, project: project, agent_id: agent_id, audit: audit} = ctx

      assert {:error, %Ecto.Changeset{} = cs} =
               Coordination.post(tenant.id, agent_id, :agent, %{
                 project_id: project.id,
                 body: "too long",
                 idempotency_key: String.duplicate("a", 256),
                 audit: audit
               })

      assert %{idempotency_key: _} = errors_on(cs)
    end

    test "AC-40.B2.3: a NUL byte in the idempotency_key is a 422, never a raw 500", ctx do
      %{tenant: tenant, project: project, agent_id: agent_id, audit: audit} = ctx

      assert {:error, %Ecto.Changeset{} = cs} =
               Coordination.post(tenant.id, agent_id, :agent, %{
                 project_id: project.id,
                 body: "nul in token",
                 idempotency_key: "before" <> <<0>> <> "after",
                 audit: audit
               })

      # The token is in @scanned_text_fields, so the NUL guard turns Postgres's raw
      # 500 into a clean 422 changeset error on :idempotency_key — nothing persists.
      assert %{idempotency_key: ["must not contain NUL bytes"]} = errors_on(cs)

      assert AdminRepo.aggregate(
               from(p in ChannelPost, where: p.project_id == ^project.id),
               :count,
               :id
             ) == 0
    end

    test "AC-40.B2.3: a denylisted credential in the idempotency_key is rejected (422)", ctx do
      %{tenant: tenant, project: project, agent_id: agent_id, audit: audit} = ctx

      # A `sk-`-shaped token must be scanned exactly like body/key/host — the
      # idempotency_key is a persisted, scanned text field, so a credential shape in
      # it is blocked rather than stored on the 30-day cross-session bus.
      assert {:error, %Ecto.Changeset{} = cs} =
               Coordination.post(tenant.id, agent_id, :agent, %{
                 project_id: project.id,
                 body: "secret in token",
                 idempotency_key: "sk-" <> String.duplicate("a", 30),
                 audit: audit
               })

      assert %{idempotency_key: [msg]} = errors_on(cs)
      assert msg =~ "secret or credential"

      assert AdminRepo.aggregate(
               from(p in ChannelPost, where: p.project_id == ^project.id),
               :count,
               :id
             ) == 0
    end

    test "a post carrying BOTH a key and an idempotency_key is rejected (422)", ctx do
      %{tenant: tenant, project: project, agent_id: agent_id, audit: audit} = ctx

      # The keyed slot and the idempotency token are orthogonal, keyless-only
      # dimensions. Sending both is nonsensical and would otherwise let a keyed post
      # ride the idempotency index (enabling out-of-scope cross-session keyed dedup),
      # so create_changeset rejects it explicitly rather than silently no-op'ing.
      assert {:error, %Ecto.Changeset{} = cs} =
               Coordination.post(tenant.id, agent_id, :agent, %{
                 project_id: project.id,
                 session_id: "S1",
                 key: "handoff:repo#812",
                 body: "both key and token",
                 idempotency_key: "abc",
                 audit: audit
               })

      assert %{idempotency_key: [msg]} = errors_on(cs)
      assert msg =~ "keyless append path only"

      assert AdminRepo.aggregate(
               from(p in ChannelPost, where: p.project_id == ^project.id),
               :count,
               :id
             ) == 0
    end

    test "two KEYED posts reusing one idempotency_key across sessions do NOT cross-session dedup",
         ctx do
      %{tenant: tenant, project: project, agent_id: agent_id, audit: audit} = ctx

      # The exact scenario from the medium review finding: two keyed posts sharing an
      # idempotency_key but from DIFFERENT sessions. Because both are rejected (a
      # keyed post may not carry a token at all), the second session's write is NEVER
      # silently dropped in favor of the first — the keyless/keyed boundary holds.
      both = fn session_id ->
        Coordination.post(tenant.id, agent_id, :agent, %{
          project_id: project.id,
          session_id: session_id,
          key: "handoff:repo#812",
          body: "keyed + token from #{session_id}",
          idempotency_key: "shared-token",
          audit: audit
        })
      end

      assert {:error, %Ecto.Changeset{}} = both.("S1")
      assert {:error, %Ecto.Changeset{}} = both.("S2")

      # Nothing landed — no keyed slot pointer, no idempotency row, no silent drop.
      assert AdminRepo.aggregate(
               from(p in ChannelPost, where: p.project_id == ^project.id),
               :count,
               :id
             ) == 0
    end

    test "TC-40.B2.5: a double-fired handoff yields one pointer slot + at most one open claim",
         ctx do
      %{tenant: tenant, project: project, agent_id: agent_id, audit: audit} = ctx

      ref = "handoff:repo#812"

      # The /handoff flow: a stable-KEY pointer post (same-session upsert) PLUS a
      # CLAIM on the ref (US-40.B1) — the cross-session exactly-once backstop for the
      # WORK. Fire the whole thing twice (a retry) from the same session.
      pointer = fn ->
        Coordination.post(tenant.id, agent_id, :agent, %{
          project_id: project.id,
          session_id: "S1",
          key: "handoff:repo#812",
          body: "handoff: finish repo#812",
          audit: audit
        })
      end

      assert {:ok, p1, :created} = pointer.()
      assert {:ok, p2, :updated} = pointer.()
      assert p2.id == p1.id

      # First claim wins; the second claim of the SAME ref by the SAME still-active
      # owner is an idempotent owner re-claim (returns the same claim), never a
      # second open claim. A genuine peer racer would get {:error, :already_claimed}.
      assert {:ok, claim1} = Coordination.claim(tenant.id, agent_id, project.id, ref)
      assert {:ok, claim2} = Coordination.claim(tenant.id, agent_id, project.id, ref)
      assert claim2.id == claim1.id

      # Exactly one pointer post and exactly one open claim survived the double-fire.
      assert AdminRepo.aggregate(
               from(p in ChannelPost, where: p.project_id == ^project.id),
               :count,
               :id
             ) == 1

      assert AdminRepo.aggregate(
               from(c in Loopctl.Coordination.ChannelClaim,
                 where: c.project_id == ^project.id and is_nil(c.done_at)
               ),
               :count,
               :id
             ) == 1
    end

    test "TC-40.B2.5: a peer's second claim of the same ref is rejected (already_claimed)", ctx do
      %{tenant: tenant, project: project, agent_id: agent_a} = ctx

      agent_b = fixture(:agent, %{tenant_id: tenant.id}).id

      fixture(:story, %{
        tenant_id: tenant.id,
        project_id: project.id,
        assigned_agent_id: agent_b,
        agent_status: :assigned
      })

      ref = "handoff:repo#812"

      assert {:ok, _claim} = Coordination.claim(tenant.id, agent_a, project.id, ref)

      # A DIFFERENT agent claiming the same ref loses the unique index → 409.
      assert {:error, :already_claimed} = Coordination.claim(tenant.id, agent_b, project.id, ref)
    end
  end

  # US-40.D3: project-scoped WRITE membership. A channel is a project_id; before
  # this story any tenant agent key could post into any project channel in the
  # tenant (a tenant-wide prompt injector, since posts auto-inject into peer
  # SessionStart). Writes now default-DENY cross-project: an `:agent` must be a
  # writable MEMBER of the target project (a story assignment), else the write is
  # rejected with the SAME {:error, :not_found} a cross-tenant project returns.
  describe "post/4 project-scoped write membership (US-40.D3)" do
    setup do
      tenant = fixture(:tenant)
      agent_id = fixture(:agent, %{tenant_id: tenant.id}).id

      audit = [
        actor_type: "api_key",
        actor_id: Ecto.UUID.generate(),
        actor_label: "agent:worker-1"
      ]

      %{tenant: tenant, agent_id: agent_id, audit: audit}
    end

    test "an agent assigned to a story in the project (a member) can post -> created", ctx do
      %{tenant: tenant, agent_id: agent_id, audit: audit} = ctx
      project = fixture(:project, %{tenant_id: tenant.id})

      fixture(:story, %{
        tenant_id: tenant.id,
        project_id: project.id,
        assigned_agent_id: agent_id,
        agent_status: :assigned
      })

      assert {:ok, _post, :created} =
               Coordination.post(tenant.id, agent_id, :agent, %{
                 project_id: project.id,
                 body: "member post",
                 audit: audit
               })
    end

    test "a non-member agent (own tenant, no story assignment) is denied and writes nothing",
         ctx do
      %{tenant: tenant, agent_id: agent_id, audit: audit} = ctx
      project = fixture(:project, %{tenant_id: tenant.id})

      # Same tenant, valid project, valid agent — but the agent is assigned to NO
      # story in this project. Default-deny: {:error, :not_found}, byte-identical
      # to the cross-tenant case, and nothing persisted.
      assert {:error, :not_found} =
               Coordination.post(tenant.id, agent_id, :agent, %{
                 project_id: project.id,
                 body: "cross-project injection",
                 audit: audit
               })

      assert AdminRepo.aggregate(ChannelPost, :count, :id) == 0

      assert AdminRepo.aggregate(
               from(a in AuditLog, where: a.entity_type == "channel_post"),
               :count,
               :id
             ) == 0
    end

    test "membership in ONE project does not grant writes to a SIBLING project in the same tenant",
         ctx do
      %{tenant: tenant, agent_id: agent_id, audit: audit} = ctx
      p1 = fixture(:project, %{tenant_id: tenant.id})
      p2 = fixture(:project, %{tenant_id: tenant.id})

      # The agent is a member of p1 only.
      fixture(:story, %{
        tenant_id: tenant.id,
        project_id: p1.id,
        assigned_agent_id: agent_id,
        agent_status: :assigned
      })

      # p1 works.
      assert {:ok, _post, :created} =
               Coordination.post(tenant.id, agent_id, :agent, %{
                 project_id: p1.id,
                 body: "my own project",
                 audit: audit
               })

      # p2 (same tenant, not a member) is denied.
      assert {:error, :not_found} =
               Coordination.post(tenant.id, agent_id, :agent, %{
                 project_id: p2.id,
                 body: "sibling project",
                 audit: audit
               })
    end

    test "membership is tenant-scoped: an assignment in another tenant's project never grants",
         ctx do
      %{tenant: tenant, agent_id: agent_id, audit: audit} = ctx
      project = fixture(:project, %{tenant_id: tenant.id})

      # Seed a story under a DIFFERENT tenant that matches BOTH the project_id and
      # the assigned_agent_id the membership query looks for — so tenant_id is the
      # SOLE discriminator. If the explicit `s.tenant_id == ^tenant_id` predicate
      # were dropped from agent_member_of_project?/3, this row would match on
      # (project_id, assigned_agent_id) and wrongly grant membership. The denial
      # below therefore proves the tenant filter is load-bearing.
      other = fixture(:tenant)

      fixture(:story, %{
        tenant_id: other.id,
        project_id: project.id,
        assigned_agent_id: agent_id,
        agent_status: :assigned
      })

      # Our agent has no assignment in OUR tenant's project -> denied, even though
      # the cross-tenant story references our project_id and our agent_id.
      assert {:error, :not_found} =
               Coordination.post(tenant.id, agent_id, :agent, %{
                 project_id: project.id,
                 body: "x",
                 audit: audit
               })
    end

    test "an elevated role (>= :user) bypasses the membership gate", ctx do
      %{tenant: tenant, agent_id: agent_id, audit: audit} = ctx
      project = fixture(:project, %{tenant_id: tenant.id})

      # No story assignment for this agent, but the caller holds :user — the
      # operator escape hatch (mirrors the redact-path bypass). Post succeeds.
      assert {:ok, _post, :created} =
               Coordination.post(tenant.id, agent_id, :user, %{
                 project_id: project.id,
                 body: "operator coordination",
                 audit: audit
               })
    end

    test "an :orchestrator (below :user) is NOT bypassed and must be a member", ctx do
      %{tenant: tenant, agent_id: agent_id, audit: audit} = ctx
      project = fixture(:project, %{tenant_id: tenant.id})

      # Documented choice: the bypass threshold is >= :user, so :orchestrator
      # (level 2) is still gated by membership. No assignment -> denied.
      assert {:error, :not_found} =
               Coordination.post(tenant.id, agent_id, :orchestrator, %{
                 project_id: project.id,
                 body: "orchestrator post",
                 audit: audit
               })
    end

    # ACCEPTED RISK (AC-40.D3.4) — documents the signed-off residual, does NOT
    # assert a bug is fixed. Membership derives from `stories.assigned_agent_id`,
    # and claiming is self-service for the `:agent` role — so a compromised agent
    # key can bootstrap its own membership of any sibling project that carries a
    # claimable pending story, then post into that channel. This is a DELIBERATE
    # accepted risk (see the `Loopctl.Coordination` moduledoc + docs/repo-
    # coordination-bus.md sign-off): the claim is an audited, work-hijacking state
    # change (observable), each post is blast-bounded by the 512-byte preview, and
    # the durable closure — binding a claim to a dispatch lineage — is Chain of
    # Custody v2 (Epic 26). This guard runs the REAL self-service contract + claim
    # flow and will break DELIBERATELY when Epic 26 tightens the claim path, forcing
    # a conscious revisit rather than a silent regression.
    test "ACCEPTED RISK (AC-40.D3.4): an :agent self-grants sibling-project membership by claiming a pending story there",
         ctx do
      %{tenant: tenant, agent_id: agent_id, audit: audit} = ctx
      sibling = fixture(:project, %{tenant_id: tenant.id})

      story =
        fixture(:story, %{
          tenant_id: tenant.id,
          project_id: sibling.id,
          agent_status: :pending
        })

      # Before the self-claim the agent is a non-member of the sibling: default-deny.
      assert {:error, :not_found} =
               Coordination.post(tenant.id, agent_id, :agent, %{
                 project_id: sibling.id,
                 body: "pre-claim injection attempt",
                 audit: audit
               })

      # Self-service contract + claim — no dispatch, no operator. The contract echo
      # (story_title/ac_count) is an anti-confusion check, not an authorization
      # barrier, so it is skipped here; `claim_story` sets `assigned_agent_id` to
      # the caller itself with no check that the work was dispatched to it.
      assert {:ok, _} =
               Progress.contract_story(tenant.id, story.id, %{},
                 agent_id: agent_id,
                 skip_contract_check: true
               )

      assert {:ok, _} = Progress.claim_story(tenant.id, story.id, agent_id: agent_id)

      # Having self-granted membership, the same agent can now post into the
      # sibling project's channel. Accepted residual — closure is Epic 26.
      assert {:ok, _post, :created} =
               Coordination.post(tenant.id, agent_id, :agent, %{
                 project_id: sibling.id,
                 body: "post-claim: membership self-granted",
                 audit: audit
               })
    end
  end

  describe "project_writable_by_agent/4 (US-40.D3 shared predicate)" do
    test "returns :ok for a member, {:error, :not_found} for a non-member" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      member = fixture(:agent, %{tenant_id: tenant.id}).id
      stranger = fixture(:agent, %{tenant_id: tenant.id}).id

      fixture(:story, %{
        tenant_id: tenant.id,
        project_id: project.id,
        assigned_agent_id: member,
        agent_status: :assigned
      })

      assert :ok = Coordination.project_writable_by_agent(tenant.id, member, project.id, :agent)

      assert {:error, :not_found} =
               Coordination.project_writable_by_agent(tenant.id, stranger, project.id, :agent)
    end

    test "an elevated role is :ok even without membership" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      agent_id = fixture(:agent, %{tenant_id: tenant.id}).id

      assert :ok = Coordination.project_writable_by_agent(tenant.id, agent_id, project.id, :user)
    end
  end

  describe "delete_post/5" do
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

    test "the author deletes their OWN post, removes it from recent, writes a 'deleted' audit row (TC-40.D2.1)",
         ctx do
      %{tenant: tenant, project: project, agent_id: agent_id, audit: audit} = ctx

      {:ok, post} =
        Coordination.create_post(tenant.id, project.id, agent_id, %{"body" => "oops, a secret"})

      # Author (agent_id) deletes their own post — role :agent is sufficient.
      assert {:ok, deleted} =
               Coordination.delete_post(tenant.id, agent_id, :agent, post.id, audit)

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

    test "a non-author agent B (role :agent) may NOT delete agent A's post; gets {:error, :not_found}, A's post survives (TC-40.D2.2)",
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

      # US-40.D2 kills the censor-and-replace vector: a non-author agent gets the
      # SAME {:error, :not_found} a missing post returns — no existence oracle.
      assert {:error, :not_found} =
               Coordination.delete_post(tenant.id, agent_b, :agent, post.id, audit_b)

      # A's post survives untouched, and no audit "deleted" row was written.
      assert %ChannelPost{} = AdminRepo.get(ChannelPost, post.id)

      assert AdminRepo.aggregate(
               from(a in AuditLog,
                 where: a.entity_type == "channel_post" and a.entity_id == ^post.id
               ),
               :count,
               :id
             ) == 0
    end

    test "an elevated (role :user) caller CAN delete agent A's post; audit actor is the elevated caller (TC-40.D2.3)",
         ctx do
      %{tenant: tenant, project: project, agent_id: agent_a} = ctx
      elevated_agent = fixture(:agent, %{tenant_id: tenant.id}).id

      {:ok, post} =
        Coordination.create_post(tenant.id, project.id, agent_a, %{"body" => "from A"})

      audit_user = [
        actor_type: "api_key",
        actor_id: Ecto.UUID.generate(),
        actor_label: "user:operator"
      ]

      # The elevated-role escape hatch (>= :user): an operator can clean up a leak
      # the author cannot (author's session gone).
      assert {:ok, _deleted} =
               Coordination.delete_post(tenant.id, elevated_agent, :user, post.id, audit_user)

      assert is_nil(AdminRepo.get(ChannelPost, post.id))

      entry = one_audit_entry(tenant.id, post.id)
      assert entry.action == "deleted"
      # The elevated DELETING actor is the audit actor — distinct from the author (A).
      assert entry.actor_label == "user:operator"
      assert entry.metadata["deleted_post_agent_id"] == agent_a
      assert entry.metadata["deleted_by_agent_id"] == elevated_agent
    end

    test "an orchestrator (role :orchestrator) non-author may NOT delete agent A's post; the gate draws at :user, not :orchestrator (TC-40.D2.4)",
         ctx do
      %{tenant: tenant, project: project, agent_id: agent_a} = ctx
      orch_agent = fixture(:agent, %{tenant_id: tenant.id}).id

      {:ok, post} =
        Coordination.create_post(tenant.id, project.id, agent_a, %{"body" => "from A"})

      audit_orch = [
        actor_type: "api_key",
        actor_id: Ecto.UUID.generate(),
        actor_label: "orchestrator:orch"
      ]

      # The elevated bypass in authorized_to_delete?/3 requires role_at_least?(role,
      # :user). orchestrator(2) < user(3), so an orchestrator sits ABOVE the route's
      # RequireRole :agent floor (it reaches this context) but BELOW the :user gate:
      # it is a non-author with an insufficient role and must be DENIED. This pins the
      # exact threshold — a regression loosening the gate to :orchestrator (letting an
      # orchestrator censor any agent's post, the vector this story kills) would flip
      # this to {:ok, _} and fail here.
      assert {:error, :not_found} =
               Coordination.delete_post(tenant.id, orch_agent, :orchestrator, post.id, audit_orch)

      # A's post survives untouched, and no audit "deleted" row was written.
      assert %ChannelPost{} = AdminRepo.get(ChannelPost, post.id)

      assert AdminRepo.aggregate(
               from(a in AuditLog,
                 where: a.entity_type == "channel_post" and a.entity_id == ^post.id
               ),
               :count,
               :id
             ) == 0
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
               Coordination.delete_post(tenant.id, agent_id, :agent, foreign_post.id, audit)

      # The other tenant's post is untouched.
      assert %ChannelPost{} = AdminRepo.get(ChannelPost, foreign_post.id)
    end

    test "a nonexistent random UUID returns {:error, :not_found} (TC-39.7.4)", ctx do
      %{tenant: tenant, agent_id: agent_id, audit: audit} = ctx

      assert {:error, :not_found} =
               Coordination.delete_post(tenant.id, agent_id, :agent, Ecto.UUID.generate(), audit)
    end

    test "a malformed (non-UUID) post id returns {:error, :not_found}, never a CastError", ctx do
      %{tenant: tenant, agent_id: agent_id, audit: audit} = ctx

      assert {:error, :not_found} =
               Coordination.delete_post(tenant.id, agent_id, :agent, "not-a-uuid", audit)
    end

    test "tenant isolation: deleting with the wrong tenant_id does not remove the row", ctx do
      %{tenant: tenant, project: project, agent_id: agent_id, audit: audit} = ctx
      other = fixture(:tenant)

      {:ok, post} =
        Coordination.create_post(tenant.id, project.id, agent_id, %{"body" => "mine"})

      # Same post id, but scoped to a different tenant → not found, row intact.
      assert {:error, :not_found} =
               Coordination.delete_post(other.id, agent_id, :agent, post.id, audit)

      assert %ChannelPost{} = AdminRepo.get(ChannelPost, post.id)
    end

    test "deleting an already-deleted post is an idempotent {:error, :not_found}, never a raise (stale-delete race)",
         ctx do
      %{tenant: tenant, project: project, agent_id: agent_id, audit: audit} = ctx

      {:ok, post} =
        Coordination.create_post(tenant.id, project.id, agent_id, %{"body" => "race"})

      assert {:ok, _deleted} =
               Coordination.delete_post(tenant.id, agent_id, :agent, post.id, audit)

      # The author re-deleting their own now-gone post is a first-class idempotency
      # case (and a stand-in for the TOCTOU race where the row vanishes between the
      # fetch and the Multi.delete). A second delete of the now-gone row must be an
      # idempotent 404 — never an Ecto.StaleEntryError/500. (This is the
      # caller-visible half of the concurrent race: run_delete/4's rescue collapses
      # a true TOCTOU stale DELETE to the identical outcome.)
      assert {:error, :not_found} =
               Coordination.delete_post(tenant.id, agent_id, :agent, post.id, audit)
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
               Coordination.delete_post(tenant.id, agent_id, :agent, post.id, bad_audit)

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
