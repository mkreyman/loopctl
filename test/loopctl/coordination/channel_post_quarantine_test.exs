defmodule Loopctl.Coordination.ChannelPostQuarantineTest do
  @moduledoc """
  The QUARANTINE lifecycle beyond detection (issue #499 review follow-up):

    * a quarantined KEYED slot is not a black hole — reposting the slot with clean
      content clears the quarantine (the write passed the current write-time gate);
    * a KEYLESS idempotent retry against a quarantined row fails loudly instead of
      reporting `:deduplicated` about a row nobody can read;
    * the operator loop actually exists — quarantined rows are readable by an operator
      and releasable, so quarantine is not a delayed delete.
  """

  use Loopctl.DataCase, async: true

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.Audit.AuditLog
  alias Loopctl.Coordination
  alias Loopctl.Coordination.ChannelPost
  alias Loopctl.Workers.ChannelPostRescanWorker

  # A denylisted loopctl-key shape (`lc_` + >= 20 chars) — fake, but matched exactly as
  # a real one would be.
  @secret "lc_abcdefghijklmnopqrstuvwxyz012345"

  setup do
    tenant = fixture(:tenant)
    project = fixture(:project, %{tenant_id: tenant.id})
    agent_id = fixture(:agent, %{tenant_id: tenant.id}).id

    # US-40.D3: writes are project-scoped by membership.
    fixture(:story, %{
      tenant_id: tenant.id,
      project_id: project.id,
      assigned_agent_id: agent_id,
      agent_status: :assigned
    })

    %{tenant: tenant, project: project, agent_id: agent_id, audit: [actor_type: "api_key"]}
  end

  # The write-time gate rejects a denylisted body, so a post that needs quarantining is
  # inserted DIRECTLY (simulating a post written before the pattern existed).
  defp insert_dirty_post(ctx, attrs) do
    %ChannelPost{
      tenant_id: ctx.tenant.id,
      project_id: ctx.project.id,
      agent_id: ctx.agent_id,
      body: "leak #{@secret}",
      expires_at: DateTime.add(DateTime.utc_now(), 30 * 86_400, :second)
    }
    |> struct(attrs)
    |> AdminRepo.insert!()
  end

  defp reload(post), do: AdminRepo.get(ChannelPost, post.id)

  describe "keyed slot remediation" do
    test "reposting a quarantined keyed slot with clean content CLEARS the quarantine", ctx do
      slot =
        insert_dirty_post(ctx, %{key: "handoff:repo#499", session_id: "sess-499"})

      assert :ok = ChannelPostRescanWorker.perform(%Oban.Job{args: %{}})
      assert %DateTime{} = reload(slot).quarantined_at

      # The single most likely remediation: repost the SAME slot WITHOUT the credential.
      assert {:ok, updated, :updated} =
               Coordination.post(ctx.tenant.id, ctx.agent_id, :agent, %{
                 project_id: ctx.project.id,
                 key: "handoff:repo#499",
                 session_id: "sess-499",
                 body: "handoff without the credential",
                 audit: ctx.audit
               })

      assert updated.id == slot.id
      assert is_nil(updated.quarantined_at)
      assert is_nil(updated.quarantine_reason)
      # Re-examined on the next rescan rather than treated as vetted.
      assert is_nil(updated.rescanned_at)

      # And it is visible again on EVERY read — the slot is not a black hole.
      assert {:ok, _} = Coordination.get_post(ctx.tenant.id, slot.id)
      assert [%{id: id}] = Coordination.recent(ctx.tenant.id, ctx.project.id)
      assert id == slot.id
    end

    # The dangerous half of clearing the quarantine on upsert: the DO UPDATE replaces
    # body/refs but PRESERVES `host` (set-once) and omitted addressing. A slot flagged
    # for a credential in one of those must NOT be silently re-published.
    test "a clean repost does NOT clear a quarantine caused by a PRESERVED field", ctx do
      slot =
        insert_dirty_post(ctx, %{
          key: "handoff:repo#501",
          session_id: "sess-501",
          body: "ordinary chatter",
          host: "box-#{@secret}"
        })

      assert :ok = ChannelPostRescanWorker.perform(%Oban.Job{args: %{}})
      assert reload(slot).quarantine_reason == "secret_denylist: host"

      assert {:error, :unprocessable_entity, message} =
               Coordination.post(ctx.tenant.id, ctx.agent_id, :agent, %{
                 project_id: ctx.project.id,
                 key: "handoff:repo#501",
                 session_id: "sess-501",
                 body: "clean body now",
                 host: "clean-box",
                 audit: ctx.audit
               })

      assert message =~ "cannot overwrite"

      # The whole transaction rolled back: the slot keeps its quarantine AND its body.
      reloaded = reload(slot)
      assert %DateTime{} = reloaded.quarantined_at
      assert reloaded.body == "ordinary chatter"
    end

    test "a repost that STILL carries the credential is rejected at write time", ctx do
      slot = insert_dirty_post(ctx, %{key: "handoff:repo#500", session_id: "sess-500"})

      assert :ok = ChannelPostRescanWorker.perform(%Oban.Job{args: %{}})

      assert {:error, %Ecto.Changeset{}} =
               Coordination.post(ctx.tenant.id, ctx.agent_id, :agent, %{
                 project_id: ctx.project.id,
                 key: "handoff:repo#500",
                 session_id: "sess-500",
                 body: "still leaking #{@secret}",
                 audit: ctx.audit
               })

      # The quarantine survives an attempted dirty overwrite.
      assert %DateTime{} = reload(slot).quarantined_at
    end
  end

  describe "keyless idempotency against a quarantined row" do
    test "a retry under a quarantined token fails loudly instead of reporting dedup", ctx do
      post =
        insert_dirty_post(ctx, %{idempotency_key: "tok-499", body: "leak #{@secret}"})

      assert :ok = ChannelPostRescanWorker.perform(%Oban.Job{args: %{}})
      assert %DateTime{} = reload(post).quarantined_at

      assert {:error, :unprocessable_entity, message} =
               Coordination.post(ctx.tenant.id, ctx.agent_id, :agent, %{
                 project_id: ctx.project.id,
                 body: "clean retry under the same token",
                 idempotency_key: "tok-499",
                 audit: ctx.audit
               })

      assert message =~ "quarantined"
      # Never leaks the matched value back to the caller.
      refute message =~ @secret
    end
  end

  describe "list_quarantined_posts/2 (operator review read)" do
    test "returns the quarantined rows every other read hides, with full bodies", ctx do
      offender = insert_dirty_post(ctx, %{})
      clean = insert_dirty_post(ctx, %{body: "ordinary chatter"})

      assert :ok = ChannelPostRescanWorker.perform(%Oban.Job{args: %{}})

      assert [row] = Coordination.list_quarantined_posts(ctx.tenant.id)
      assert row.id == offender.id
      assert row.body =~ @secret
      assert row.quarantine_reason == "secret_denylist: body"

      # The clean post is NOT in the review list (it was never quarantined).
      refute Enum.any?(Coordination.list_quarantined_posts(ctx.tenant.id), &(&1.id == clean.id))
    end

    test "is tenant-scoped: tenant A never sees tenant B's quarantined rows", ctx do
      other_tenant = fixture(:tenant)
      other_project = fixture(:project, %{tenant_id: other_tenant.id})
      other_agent = fixture(:agent, %{tenant_id: other_tenant.id}).id

      insert_dirty_post(ctx, %{})

      %ChannelPost{
        tenant_id: other_tenant.id,
        project_id: other_project.id,
        agent_id: other_agent,
        body: "leak #{@secret}",
        expires_at: DateTime.add(DateTime.utc_now(), 30 * 86_400, :second)
      }
      |> AdminRepo.insert!()

      assert :ok = ChannelPostRescanWorker.perform(%Oban.Job{args: %{}})

      assert [a] = Coordination.list_quarantined_posts(ctx.tenant.id)
      assert [b] = Coordination.list_quarantined_posts(other_tenant.id)
      assert a.tenant_id == ctx.tenant.id
      assert b.tenant_id == other_tenant.id
    end

    test "filters by project and clamps the limit; a malformed filter returns nothing", ctx do
      insert_dirty_post(ctx, %{})
      assert :ok = ChannelPostRescanWorker.perform(%Oban.Job{args: %{}})

      assert [_] = Coordination.list_quarantined_posts(ctx.tenant.id, project_id: ctx.project.id)

      assert [] =
               Coordination.list_quarantined_posts(ctx.tenant.id,
                 project_id: Ecto.UUID.generate()
               )

      # A malformed project filter must never widen the read, and never raise.
      assert [] = Coordination.list_quarantined_posts(ctx.tenant.id, project_id: "not-a-uuid")
      assert [] = Coordination.list_quarantined_posts("not-a-uuid")
      # An absurd limit is clamped, not passed through.
      assert length(Coordination.list_quarantined_posts(ctx.tenant.id, limit: 10_000)) == 1
    end
  end

  describe "release_post/3 (operator exoneration)" do
    test "clears the quarantine, restores every read, and audits the release", ctx do
      offender = insert_dirty_post(ctx, %{body: "false positive #{@secret}"})

      assert :ok = ChannelPostRescanWorker.perform(%Oban.Job{args: %{}})
      assert {:error, :not_found} = Coordination.get_post(ctx.tenant.id, offender.id)

      assert {:ok, released} = Coordination.release_post(ctx.tenant.id, offender.id, ctx.audit)

      assert is_nil(released.quarantined_at)
      assert is_nil(released.quarantine_reason)
      assert %DateTime{} = released.quarantine_released_at

      assert {:ok, _} = Coordination.get_post(ctx.tenant.id, offender.id)
      assert [%{id: id}] = Coordination.recent(ctx.tenant.id, ctx.project.id)
      assert id == offender.id

      assert [entry] =
               from(a in AuditLog,
                 where:
                   a.tenant_id == ^ctx.tenant.id and a.entity_id == ^offender.id and
                     a.action == "quarantine_released"
               )
               |> AdminRepo.all()

      assert entry.metadata["cleared_reason"] == "secret_denylist: body"
      refute inspect(entry.metadata) =~ @secret
    end

    test "the release is DURABLE — the next rescan does not re-quarantine the row", ctx do
      offender = insert_dirty_post(ctx, %{body: "false positive #{@secret}"})

      assert :ok = ChannelPostRescanWorker.perform(%Oban.Job{args: %{}})
      assert {:ok, _} = Coordination.release_post(ctx.tenant.id, offender.id, ctx.audit)

      # Same patterns, next run: without the release marker this would re-flag instantly.
      assert :ok = ChannelPostRescanWorker.perform(%Oban.Job{args: %{}})

      assert is_nil(reload(offender).quarantined_at)
    end

    test "is oracle-safe: unknown, malformed, foreign-tenant and non-quarantined all 404",
         ctx do
      live = insert_dirty_post(ctx, %{body: "ordinary chatter"})
      other_tenant = fixture(:tenant)

      assert {:error, :not_found} =
               Coordination.release_post(ctx.tenant.id, Ecto.UUID.generate(), ctx.audit)

      assert {:error, :not_found} = Coordination.release_post(ctx.tenant.id, "nope", ctx.audit)
      assert {:error, :not_found} = Coordination.release_post("nope", live.id, ctx.audit)

      # A live (never quarantined) post cannot be "released" — nothing to clear.
      assert {:error, :not_found} = Coordination.release_post(ctx.tenant.id, live.id, ctx.audit)

      # Cross-tenant is byte-identical to nonexistent.
      insert_dirty_post(ctx, %{})
      assert :ok = ChannelPostRescanWorker.perform(%Oban.Job{args: %{}})
      [quarantined] = Coordination.list_quarantined_posts(ctx.tenant.id)

      assert {:error, :not_found} =
               Coordination.release_post(other_tenant.id, quarantined.id, ctx.audit)
    end
  end
end
