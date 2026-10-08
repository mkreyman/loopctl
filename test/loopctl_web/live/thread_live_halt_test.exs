defmodule LoopctlWeb.ThreadLiveHaltTest do
  @moduledoc """
  US-45.7 — the thread page and a human finding under a custody HALT.

  The halt is the thread's one halt check, `Runners.custody_halted?/1`, which reads the tenant
  on `AdminRepo`, while the page's session and the thread live on the RLS `Repo`. In test both
  run on the test's one sandbox connection (`Loopctl.AdminRepo.Route`), so the halt the test
  writes on `AdminRepo` is the one the page reads, and nothing is committed. Everything else
  about the page is in `LoopctlWeb.ThreadLiveTest`.
  """

  use LoopctlWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Loopctl.AdminRepo
  alias Loopctl.Repo
  alias Loopctl.Tenants.Tenant
  alias Loopctl.Threads
  alias Loopctl.Threads.Entry
  alias Loopctl.WorkBreakdown.Story
  alias LoopctlWeb.BrowserAuth

  setup :verify_on_exit!

  @epoch 2

  setup %{conn: conn} do
    tenant = fixture(:tenant, %{trust_tier: :human_anchored})
    auth = fixture(:root_authenticator, tenant_id: tenant.id, repo: Repo)

    session =
      fixture(:browser_session, %{tenant_id: tenant.id, authenticator_id: auth.id, repo: Repo})

    story = fixture(:ledger_story, %{tenant_id: tenant.id, claim_epoch: @epoch})
    agent = fixture(:stage_agent, %{tenant_id: tenant.id})

    {:ok, _} =
      Repo.with_tenant(tenant.id, fn ->
        from(s in Story, where: s.id == ^story.id)
        |> Repo.update_all(
          set: [
            assigned_agent_id: agent.id,
            agent_status: :implementing,
            claimed_until: DateTime.add(DateTime.utc_now(), 3_600)
          ]
        )
      end)

    {:ok, cp, :created} =
      Threads.record_checkpoint(tenant.id, story.id,
        agent_id: agent.id,
        claim_epoch: @epoch,
        commit_sha: String.duplicate("1", 40),
        tree_sha: String.duplicate("e", 40),
        author_principal: "agent:#{agent.id}",
        actor_lineage: []
      )

    conn =
      init_test_session(conn, %{
        BrowserAuth.session_key() => %{"tenant_id" => tenant.id, "session_id" => session.id}
      })

    %{conn: conn, tenant: tenant, story: story, cp: cp}
  end

  defp halt_custody(ctx) do
    AdminRepo.update_all(from(t in Tenant, where: t.id == ^ctx.tenant.id),
      set: [custody_halted_at: DateTime.utc_now()]
    )
  end

  defp entries(ctx, kind) do
    {:ok, rows} =
      Repo.with_tenant(ctx.tenant.id, fn ->
        Repo.all(from e in Entry, where: e.story_id == ^ctx.story.id and e.kind == ^kind)
      end)

    rows
  end

  defp finding(ctx, key) do
    Threads.record_human_finding(ctx.tenant.id, ctx.story.id, %{
      "idempotency_key" => key,
      "body" => "b",
      "checkpoint_id" => ctx.cp.id,
      "severity" => "high"
    })
  end

  test "a halted tenant reads, writes a message, and is refused a finding", ctx do
    halt_custody(ctx)

    {:ok, view, _html} = live(ctx.conn, ~p"/threads/#{ctx.story.id}")
    assert has_element?(view, "#thread-halted")

    view
    |> form("#finding-form")
    |> render_submit(%{
      finding: %{
        nonce: "fnonce-0123456789",
        checkpoint_id: ctx.cp.id,
        severity: "high",
        body: "b"
      }
    })

    assert has_element?(view, "#finding-notice", "halted")
    assert [] == entries(ctx, :finding)

    view
    |> form("#message-form")
    |> render_submit(%{message: %{nonce: "mnonce-0123456789", body: "hi"}})

    assert [_message] = entries(ctx, :message)
  end

  test "a halted tenant is refused a new finding; the resend of a recorded one is answered",
       ctx do
    {:ok, %{entry: entry}, :created} = finding(ctx, "before-halt")
    halt_custody(ctx)

    assert {:error, :tenant_halted} = finding(ctx, "after-halt")
    assert {:ok, %{entry: ^entry}, :existing} = finding(ctx, "before-halt")
  end
end
