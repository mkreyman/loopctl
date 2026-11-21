defmodule Loopctl.CoordinationClaimHolderTest do
  @moduledoc """
  US-52.14 (AC-52.14.6, AC-52.14.7): a channel claim names its holder, so a peer session of
  the same agent is refused instead of being handed the claim as its own (KB 0264d7e0), and
  cannot mark it done or release it whatever `claimed_by_session` it sends.
  """
  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  alias Loopctl.Coordination
  alias Loopctl.Holders

  defp audit, do: [actor_type: "api_key", actor_id: Ecto.UUID.generate(), actor_label: "agent:w"]

  defp member do
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

  defp holder(ctx, session_id) do
    attrs = %{"kind" => "interactive", "session_id" => session_id, "host" => "minis"}
    {:ok, %{holder: holder}} = Holders.register(ctx.tenant.id, ctx.agent_id, attrs)
    holder.id
  end

  defp claim(ctx, holder_id, ref \\ "handoff:r") do
    Coordination.claim(ctx.tenant.id, ctx.agent_id, ctx.project.id, ref,
      role: :agent,
      holder_id: holder_id,
      session_id: "sess-#{holder_id}",
      audit: audit()
    )
  end

  setup do
    ctx = member()
    Map.merge(ctx, %{h1: holder(ctx, "s1"), h2: holder(ctx, "s2")})
  end

  test "the claim is stamped with the caller's holder", ctx do
    assert {:ok, claim} = claim(ctx, ctx.h1)
    assert claim.claimant_holder_id == ctx.h1
  end

  test "a second holder of the same agent is already_claimed; the holder itself is already_held",
       ctx do
    {:ok, _} = claim(ctx, ctx.h1)

    assert {:error, :already_claimed} = claim(ctx, ctx.h2)
    assert {:error, :already_claimed} = claim(ctx, nil)
    assert {:ok, _, :already_held} = claim(ctx, ctx.h1)
  end

  test "done and release by another holder are not_found, whatever session it claims", ctx do
    {:ok, _} = claim(ctx, ctx.h1)
    spoofed = [session_id: "sess-#{ctx.h1}", holder_id: ctx.h2]

    assert {:error, :not_found} =
             Coordination.done(
               ctx.tenant.id,
               ctx.agent_id,
               ctx.project.id,
               "handoff:r",
               audit(),
               spoofed
             )

    assert {:error, :not_found} =
             Coordination.release(
               ctx.tenant.id,
               ctx.agent_id,
               ctx.project.id,
               "handoff:r",
               audit(),
               spoofed
             )

    assert {:ok, %{done_at: %DateTime{}}} =
             Coordination.done(ctx.tenant.id, ctx.agent_id, ctx.project.id, "handoff:r", audit(),
               session_id: "sess-#{ctx.h1}",
               holder_id: ctx.h1
             )
  end

  test "a claim made with no holder stays agent-scoped", ctx do
    {:ok, _} = claim(ctx, nil)

    assert {:ok, _} =
             Coordination.release(
               ctx.tenant.id,
               ctx.agent_id,
               ctx.project.id,
               "handoff:r",
               audit(),
               session_id: "sess-",
               holder_id: ctx.h1
             )
  end

  test "tenant isolation: another tenant's holder claims the same ref freely", ctx do
    {:ok, _} = claim(ctx, ctx.h1)
    other = member()

    assert {:ok, claim} = claim(other, holder(other, "s1"))
    assert claim.tenant_id == other.tenant.id
  end
end
