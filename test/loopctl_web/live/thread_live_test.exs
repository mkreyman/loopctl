defmodule LoopctlWeb.ThreadLiveTest do
  @moduledoc """
  US-45.7 — the thread page (TC-45.7.2, TC-45.7.3) and the session guarding it.

  `async: false`: the session is validated on `AdminRepo` (the tenant, its authenticator, its
  halt) while the thread lives on the RLS `Repo`, which are separate sandbox connections, so
  the tenant is committed — the shape `LoopctlWeb.ThreadControllerTest` gives for the same
  reason. The authenticator stays on the `AdminRepo` sandbox, which is the only connection that
  reads it.
  """

  use LoopctlWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Loopctl.Repo
  alias Loopctl.Tenants
  alias Loopctl.Tenants.RootAuthenticators
  alias Loopctl.Threads
  alias Loopctl.Threads.Entry
  alias Loopctl.WebAuthn.BrowserLogin
  alias Loopctl.WorkBreakdown.Story
  alias LoopctlWeb.BrowserAuth

  setup :verify_on_exit!

  setup_all do
    sweep_committed_runner_tenants()
    on_exit(&sweep_committed_runner_tenants/0)
    :ok
  end

  @epoch 2
  @tree String.duplicate("e", 40)
  @sha1 String.duplicate("1", 40)
  @sha2 String.duplicate("2", 40)

  setup %{conn: conn} do
    tenant = fixture(:committed_tenant, %{trust_tier: :human_anchored})
    authenticator = fixture(:root_authenticator, tenant_id: tenant.id)
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

    fixture(:intake_record, %{
      tenant_id: tenant.id,
      project_id: story.project_id,
      repo_full_name: "acme/widgets"
    })

    ctx = %{tenant: tenant, authenticator: authenticator, story: story, agent: agent}
    {:ok, Map.put(ctx, :conn, signed_in(conn, tenant, authenticator))}
  end

  defp signed_in(conn, tenant, authenticator, at \\ System.system_time(:second)) do
    init_test_session(conn, %{
      BrowserAuth.session_key() =>
        BrowserLogin.to_session(%{
          tenant_id: tenant.id,
          authenticator_id: authenticator.id,
          authenticated_at: at
        })
    })
  end

  defp checkpoint(ctx, sha) do
    {:ok, cp, :created} =
      Threads.record_checkpoint(ctx.tenant.id, ctx.story.id,
        agent_id: ctx.agent.id,
        claim_epoch: @epoch,
        commit_sha: sha,
        tree_sha: @tree,
        note: "implemented the thing",
        author_principal: "agent:#{ctx.agent.id}",
        actor_lineage: []
      )

    cp
  end

  defp entries(ctx, kind) do
    {:ok, rows} =
      Repo.with_tenant(ctx.tenant.id, fn ->
        Repo.all(from e in Entry, where: e.story_id == ^ctx.story.id and e.kind == ^kind)
      end)

    rows
  end

  defp open(ctx), do: live(ctx.conn, ~p"/threads/#{ctx.story.id}")

  describe "the session guard (AC-45.7.1)" do
    test "an unauthenticated request is sent to /login, remembering the thread", ctx do
      conn = get(build_conn(), ~p"/threads/#{ctx.story.id}")
      assert redirected_to(conn) == ~p"/login"
      assert get_session(conn, "browser_return_to") == "/threads/#{ctx.story.id}"
    end

    test "an expired session, and a revoked authenticator, are refused at the request", ctx do
      stale = System.system_time(:second) - BrowserLogin.lifetime_seconds() - 5

      expired =
        build_conn()
        |> signed_in(ctx.tenant, ctx.authenticator, stale)
        |> get(~p"/threads/#{ctx.story.id}")

      assert redirected_to(expired) == ~p"/login"

      {:ok, _} = RootAuthenticators.delete(ctx.tenant.id, ctx.authenticator.id)
      assert redirected_to(get(ctx.conn, ~p"/threads/#{ctx.story.id}")) == ~p"/login"
    end

    test "the LiveView mount validates on its own, without the router's plug" do
      assert {:halt, _socket} =
               BrowserAuth.on_mount(
                 :require_browser_session,
                 %{},
                 %{},
                 %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, flash: %{}}}
               )
    end

    test "the thread page's live_session runs the session check on every mount", ctx do
      %{phoenix_live_view: {LoopctlWeb.ThreadLive, :show, _opts, %{extra: extra}}} =
        Phoenix.Router.route_info(LoopctlWeb.Router, "GET", "/threads/#{ctx.story.id}", "")

      assert Enum.any?(
               extra.on_mount,
               &match?(%{id: {LoopctlWeb.BrowserAuth, :require_browser_session}}, &1)
             )
    end

    test "tenant isolation: another tenant's human does not see the thread", ctx do
      other = fixture(:committed_tenant, %{trust_tier: :human_anchored})
      other_auth = fixture(:root_authenticator, tenant_id: other.id)

      {:ok, view, _html} =
        build_conn()
        |> signed_in(other, other_auth)
        |> live(~p"/threads/#{ctx.story.id}")

      assert has_element?(view, "#thread-not-found")
      refute has_element?(view, "#thread-page")
    end
  end

  describe "rendering (TC-45.7.2)" do
    test "checkpoints with kind and CI evidence; entries fenced as untrusted text", ctx do
      cp = checkpoint(ctx, @sha1)

      :ok =
        Threads.record_gate_evidence(ctx.tenant.id, ctx.story.id, cp.id, "ci", %{
          "sha" => @sha1,
          "read_at" => "2026-09-27T10:00:00.000000Z",
          "passed" => ["test"],
          "pending" => [],
          "missing" => [],
          "failed" => [],
          "jobs" => [%{"name" => "test", "conclusion" => "success"}]
        })

      {:ok, _, :created} =
        Threads.record_entry(
          ctx.tenant.id,
          ctx.story.id,
          %{
            "kind" => "message",
            "idempotency_key" => "m1",
            "body" => "<script>alert(1)</script> **not bold**"
          },
          author_principal: "agent:#{ctx.agent.id}",
          actor_lineage: []
        )

      {:ok, view, _html} = open(ctx)

      assert has_element?(view, "#checkpoint-#{cp.id}", "checkpoint")
      assert has_element?(view, "#ci-#{cp.id}", "1 passed")

      assert has_element?(
               view,
               "#thread-entries pre[data-untrusted]",
               "<script>alert(1)</script>"
             )

      assert has_element?(view, "#thread-entries pre[data-untrusted]", "**not bold**")
      refute has_element?(view, "#thread-entries script")
      refute has_element?(view, "#thread-entries strong")
    end

    test "a diff is fetched from the forge by SHA, against the parent checkpoint", ctx do
      cp1 = checkpoint(ctx, @sha1)
      cp2 = checkpoint(ctx, @sha2)

      expect(Loopctl.MockPullRequestSource, :checkpoint_diff, fn "acme/widgets", @sha1, @sha2 ->
        {:ok, %{text: "diff --git a/x b/x\n+the added line", truncated: false}}
      end)

      {:ok, view, _html} = open(ctx)
      view |> element("#diff-button-#{cp2.id}") |> render_click()
      render_async(view)

      assert has_element?(view, "#diff-#{cp2.id}", "+the added line")
      refute has_element?(view, "#diff-#{cp1.id}")
    end

    test "a slow forge leaves the ledger rendered; a down one is shown where the diff goes",
         ctx do
      cp = checkpoint(ctx, @sha1)
      test_pid = self()

      expect(Loopctl.MockPullRequestSource, :checkpoint_diff, fn _repo, nil, @sha1 ->
        send(test_pid, {:forge_asked, self()})

        receive do
          :answer -> {:error, {:github_unreachable, :timeout}}
        after
          5_000 -> {:error, :test_timeout}
        end
      end)

      {:ok, view, _html} = open(ctx)
      view |> element("#diff-button-#{cp.id}") |> render_click()
      assert_receive {:forge_asked, forge}

      assert has_element?(view, "#diff-#{cp.id}", "fetching")
      assert has_element?(view, "#thread-entries pre", "implemented the thing")

      send(forge, :answer)
      render_async(view)
      assert has_element?(view, "#diff-#{cp.id}", "did not answer")
    end
  end

  describe "writing (TC-45.7.3)" do
    test "the same message form submitted twice is one entry, the human's, with no lineage",
         ctx do
      checkpoint(ctx, @sha1)
      {:ok, view, _html} = open(ctx)

      nonce =
        view |> element("#message-form input[name='message[nonce]']") |> render() |> nonce_of()

      params = %{message: %{body: "looks right to me", nonce: nonce}}

      view |> form("#message-form") |> render_submit(params)
      view |> form("#message-form") |> render_submit(params)

      assert [message] = entries(ctx, :message)
      assert message.idempotency_key == nonce
      assert message.author_principal == "human:webauthn"
      assert message.dispatch_id == nil
      assert has_element?(view, "#message-notice", "Recorded")
    end

    test "a finding form submitted twice is one finding, bound to the checkpoint", ctx do
      cp = checkpoint(ctx, @sha1)
      {:ok, view, _html} = open(ctx)

      nonce =
        view |> element("#finding-form input[name='finding[nonce]']") |> render() |> nonce_of()

      params = %{
        finding: %{
          nonce: nonce,
          checkpoint_id: cp.id,
          severity: "high",
          location: "lib/a.ex:1",
          introduced_by: "",
          body: "the lock is taken after the chain"
        }
      }

      view |> form("#finding-form") |> render_submit(params)
      view |> form("#finding-form") |> render_submit(params)

      assert [finding] = entries(ctx, :finding)
      assert finding.checkpoint_id == cp.id and finding.author_principal == "human:webauthn"
      assert has_element?(view, "#finding-#{finding.id}", "lib/a.ex:1")
    end

    test "a halted tenant reads, writes a message, and is refused a finding", ctx do
      cp = checkpoint(ctx, @sha1)
      {:ok, _} = Tenants.halt_custody(ctx.tenant.id)

      {:ok, view, _html} = open(ctx)
      assert has_element?(view, "#thread-halted")

      view
      |> form("#finding-form")
      |> render_submit(%{
        finding: %{nonce: "f1", checkpoint_id: cp.id, severity: "high", body: "b"}
      })

      assert has_element?(view, "#finding-notice", "halted")
      assert [] == entries(ctx, :finding)

      view |> form("#message-form") |> render_submit(%{message: %{nonce: "m1", body: "hi"}})
      assert [_message] = entries(ctx, :message)
    end

    test "a revoked authenticator refuses an open page's next write", ctx do
      checkpoint(ctx, @sha1)
      {:ok, view, _html} = open(ctx)
      {:ok, _} = RootAuthenticators.delete(ctx.tenant.id, ctx.authenticator.id)

      assert {:error, {:redirect, %{to: "/login"}}} =
               view
               |> form("#message-form")
               |> render_submit(%{message: %{nonce: "m1", body: "after revoke"}})

      assert [] == entries(ctx, :message)
    end

    test "the revalidation timer signs an idle page out", ctx do
      checkpoint(ctx, @sha1)
      {:ok, view, _html} = open(ctx)
      {:ok, _} = RootAuthenticators.delete(ctx.tenant.id, ctx.authenticator.id)

      send(view.pid, :revalidate)
      assert_redirect(view, "/login")
    end
  end

  defp nonce_of(html) do
    [_, value] = Regex.run(~r/value="([^"]+)"/, html)
    value
  end
end
