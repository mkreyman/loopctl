defmodule Loopctl.Coordination.DirectedHandoffsTest do
  @moduledoc """
  US-40.C1 — `Loopctl.Coordination.directed_handoffs/3`, the directed-handoff
  discovery read: DIRECTED, OPEN, UNCLAIMED handoffs surfaced as a pinned set,
  never subject to the newest-N recency truncation of channel_recent.

  Everything runs via `Loopctl.AdminRepo` (one sandbox connection), so `async: true`.
  """
  use Loopctl.DataCase, async: true

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.Coordination
  alias Loopctl.Coordination.ChannelPost

  setup do
    tenant = fixture(:tenant)
    project = fixture(:project, %{tenant_id: tenant.id})
    agent_id = fixture(:agent, %{tenant_id: tenant.id}).id
    %{tenant: tenant, project: project, agent_id: agent_id}
  end

  # Insert a handoff post DIRECTLY on AdminRepo (bypassing the write membership
  # gate + the session-required-for-key changeset rule) so discovery-read tests can
  # seed arbitrary addressing/keys/timestamps. A handoff IS a post with a
  # `handoff:<anchor>` key (US-40.B2).
  defp handoff(ctx, attrs) do
    attrs = Enum.into(attrs, %{})
    now = DateTime.utc_now()

    AdminRepo.insert!(%ChannelPost{
      tenant_id: Map.get(attrs, :tenant_id, ctx.tenant.id),
      project_id: Map.get(attrs, :project_id, ctx.project.id),
      agent_id: Map.get(attrs, :agent_id, ctx.agent_id),
      body: Map.get(attrs, :body, "please pick up this handoff"),
      key: Map.get(attrs, :key, "handoff:repo##{System.unique_integer([:positive])}"),
      to_host: Map.get(attrs, :to_host),
      to_capability: Map.get(attrs, :to_capability),
      expires_at: Map.get(attrs, :expires_at, DateTime.add(now, 30 * 86_400, :second))
    })
  end

  # A plain keyless status post (no handoff key) — never a handoff.
  defp status_post(ctx, body) do
    now = DateTime.utc_now()

    AdminRepo.insert!(%ChannelPost{
      tenant_id: ctx.tenant.id,
      project_id: ctx.project.id,
      agent_id: ctx.agent_id,
      body: body,
      expires_at: DateTime.add(now, 30 * 86_400, :second)
    })
  end

  defp keys(rows), do: Enum.map(rows, & &1.key)

  describe "directed_handoffs/3" do
    # TC-40.C1.1
    test "returns a capability-directed handoff with no open claim", ctx do
      handoff(ctx, %{key: "handoff:repo#812", to_capability: "fly-auth"})

      assert [row] =
               Coordination.directed_handoffs(ctx.tenant.id, ctx.project.id, %{
                 capabilities: ["fly-auth"]
               })

      assert row.key == "handoff:repo#812"
      # It is the SHARED bounded read-model projection — a preview, never a full body.
      assert row.body_preview == "please pick up this handoff"
      assert row.truncated == false
      refute Map.has_key?(row, :body)
      assert row.to_capability == "fly-auth"
    end

    # TC-40.C1.2
    test "a handoff with an OPEN claim on its ref is excluded", ctx do
      handoff(ctx, %{key: "handoff:repo#812", to_capability: "fly-auth"})

      # OPEN = done_at IS NULL AND lease not expired.
      fixture(:channel_claim, %{
        tenant_id: ctx.tenant.id,
        project_id: ctx.project.id,
        ref: "handoff:repo#812",
        done_at: nil,
        lease_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
      })

      assert [] ==
               Coordination.directed_handoffs(ctx.tenant.id, ctx.project.id, %{
                 capabilities: ["fly-auth"]
               })
    end

    # TC-40.C1.3
    test "a RELEASED claim reopens the handoff; a DONE claim keeps it excluded (done terminal)",
         ctx do
      # X: released — model release as "no claim row exists" (release DELETES the claim).
      handoff(ctx, %{key: "handoff:x", to_capability: "fly-auth"})

      # Y: DONE — done_at set. DONE is terminal: Y must NOT reappear.
      handoff(ctx, %{key: "handoff:y", to_capability: "fly-auth"})

      fixture(:channel_claim, %{
        tenant_id: ctx.tenant.id,
        project_id: ctx.project.id,
        ref: "handoff:y",
        done_at: DateTime.utc_now(),
        lease_expires_at: DateTime.add(DateTime.utc_now(), -60, :second)
      })

      rows =
        Coordination.directed_handoffs(ctx.tenant.id, ctx.project.id, %{
          capabilities: ["fly-auth"]
        })

      assert keys(rows) == ["handoff:x"]
    end

    test "a lease that expired WITHOUT completion reopens the handoff", ctx do
      handoff(ctx, %{key: "handoff:stale", to_capability: "fly-auth"})

      # done_at IS NULL AND lease expired → NOT active → handoff reappears.
      fixture(:channel_claim, %{
        tenant_id: ctx.tenant.id,
        project_id: ctx.project.id,
        ref: "handoff:stale",
        done_at: nil,
        lease_expires_at: DateTime.add(DateTime.utc_now(), -60, :second)
      })

      assert [row] =
               Coordination.directed_handoffs(ctx.tenant.id, ctx.project.id, %{
                 capabilities: ["fly-auth"]
               })

      assert row.key == "handoff:stale"
    end

    # TC-40.C1.4
    test "a directed handoff is PINNED — returned even behind 150 newer status posts", ctx do
      handoff(ctx, %{key: "handoff:pinned", to_capability: "fly-auth"})
      for i <- 1..150, do: status_post(ctx, "status #{i}")

      assert [row] =
               Coordination.directed_handoffs(ctx.tenant.id, ctx.project.id, %{
                 capabilities: ["fly-auth"]
               })

      assert row.key == "handoff:pinned"
    end

    # TC-40.C1.5
    test "another tenant's directed handoff is not visible (empty set, tenant-scoped)", ctx do
      other_tenant = fixture(:tenant)
      other_project = fixture(:project, %{tenant_id: other_tenant.id})
      other_agent = fixture(:agent, %{tenant_id: other_tenant.id}).id

      handoff(ctx, %{
        tenant_id: other_tenant.id,
        project_id: other_project.id,
        agent_id: other_agent,
        key: "handoff:theirs",
        to_capability: "fly-auth"
      })

      # Querying OUR tenant/project sees nothing.
      assert [] ==
               Coordination.directed_handoffs(ctx.tenant.id, ctx.project.id, %{
                 capabilities: ["fly-auth"]
               })

      # And the other tenant, cross to our project, also sees nothing (no cross-tenant leak).
      assert [] ==
               Coordination.directed_handoffs(other_tenant.id, ctx.project.id, %{
                 capabilities: ["fly-auth"]
               })
    end

    # TC-40.C1.6
    test "a handoff addressed to a capability the caller lacks is not returned", ctx do
      handoff(ctx, %{key: "handoff:signing", to_capability: "windows-signing"})

      assert [] ==
               Coordination.directed_handoffs(ctx.tenant.id, ctx.project.id, %{
                 capabilities: ["fly-auth"]
               })
    end

    # TC-40.C1.7
    test "a plain keyless status post is never returned (only key LIKE 'handoff:%')", ctx do
      status_post(ctx, "just a status, no handoff key")

      assert [] ==
               Coordination.directed_handoffs(ctx.tenant.id, ctx.project.id, %{
                 capabilities: ["fly-auth"]
               })
    end

    test "a host-directed handoff is returned when the caller's host matches", ctx do
      handoff(ctx, %{key: "handoff:to-mac", to_host: "mac-mini"})

      assert [row] =
               Coordination.directed_handoffs(ctx.tenant.id, ctx.project.id, %{host: "mac-mini"})

      assert row.key == "handoff:to-mac"

      # A different host does not match.
      assert [] ==
               Coordination.directed_handoffs(ctx.tenant.id, ctx.project.id, %{host: "beelink"})
    end

    test "a BROADCAST handoff (no addressing) is included by default so nothing is orphaned",
         ctx do
      handoff(ctx, %{key: "handoff:broadcast", to_host: nil, to_capability: nil})

      # Included even with no target filter at all.
      assert [row] = Coordination.directed_handoffs(ctx.tenant.id, ctx.project.id, %{})
      assert row.key == "handoff:broadcast"

      # And still included alongside a capability filter.
      assert [_] =
               Coordination.directed_handoffs(ctx.tenant.id, ctx.project.id, %{
                 capabilities: ["fly-auth"]
               })
    end

    test "an expired handoff is excluded (expires_at > now)", ctx do
      handoff(ctx, %{
        key: "handoff:expired",
        to_capability: "fly-auth",
        expires_at: DateTime.add(DateTime.utc_now(), -60, :second)
      })

      assert [] ==
               Coordination.directed_handoffs(ctx.tenant.id, ctx.project.id, %{
                 capabilities: ["fly-auth"]
               })
    end

    test "capabilities accepts a comma-joined string hint", ctx do
      handoff(ctx, %{key: "handoff:csv", to_capability: "fly-auth"})

      assert [row] =
               Coordination.directed_handoffs(ctx.tenant.id, ctx.project.id, %{
                 capabilities: "windows-signing, fly-auth"
               })

      assert row.key == "handoff:csv"
    end

    test "an empty capabilities list still returns host-directed and broadcast handoffs", ctx do
      handoff(ctx, %{key: "handoff:bcast", to_host: nil, to_capability: nil})
      handoff(ctx, %{key: "handoff:cap-only", to_capability: "fly-auth"})

      rows = Coordination.directed_handoffs(ctx.tenant.id, ctx.project.id, %{capabilities: []})
      # Broadcast is included; the capability-directed one is NOT (empty caps).
      assert keys(rows) == ["handoff:bcast"]
    end

    test "ordering pins oldest-unclaimed-first so a stale handoff floats up", ctx do
      older =
        handoff(ctx, %{
          key: "handoff:older",
          to_capability: "fly-auth",
          expires_at: DateTime.add(DateTime.utc_now(), 30 * 86_400, :second)
        })

      _newer = handoff(ctx, %{key: "handoff:newer", to_capability: "fly-auth"})

      # Force `older` to have an earlier inserted_at so ordering is deterministic.
      AdminRepo.update_all(
        from(p in ChannelPost, where: p.id == ^older.id),
        set: [inserted_at: DateTime.add(DateTime.utc_now(), -3600, :second)]
      )

      rows =
        Coordination.directed_handoffs(ctx.tenant.id, ctx.project.id, %{
          capabilities: ["fly-auth"]
        })

      assert keys(rows) == ["handoff:older", "handoff:newer"]
    end

    test "a malformed project_id returns [] (valid_uuid? guard, never a crash)", ctx do
      assert [] ==
               Coordination.directed_handoffs(ctx.tenant.id, "not-a-uuid", %{
                 capabilities: ["fly-auth"]
               })

      assert [] ==
               Coordination.directed_handoffs("not-a-uuid", ctx.project.id, %{
                 capabilities: ["fly-auth"]
               })
    end

    test "a nonexistent (well-formed) project_id returns [] (never a 404-shaped error)", ctx do
      assert [] ==
               Coordination.directed_handoffs(ctx.tenant.id, Ecto.UUID.generate(), %{
                 capabilities: ["fly-auth"]
               })
    end
  end
end
