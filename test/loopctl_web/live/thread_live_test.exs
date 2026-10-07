defmodule LoopctlWeb.ThreadLiveTest do
  @moduledoc """
  US-45.7 — the thread page (TC-45.7.2, TC-45.7.3) and the session guarding it.

  Everything the page reads — its session, the tenant's status and halt, the thread — is read
  under the tenant's RLS on `Loopctl.Repo`, so the whole fixture lives on that one sandbox
  connection and the module runs async.
  """

  use LoopctlWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Loopctl.Intake.Source
  alias Loopctl.Repo
  alias Loopctl.Tenants.RootAuthenticator
  alias Loopctl.Threads
  alias Loopctl.Threads.Entry
  alias Loopctl.WebAuthn.BrowserLogin
  alias Loopctl.WebAuthn.BrowserSession
  alias Loopctl.WorkBreakdown.Story
  alias LoopctlWeb.BrowserAuth

  setup :verify_on_exit!

  # render_async/1 waits 100ms by default. Under a loaded full-suite run that is not enough
  # for the diff and checkpoint fetches, and TC-45.7.2 failed on it once (2026-10-07) while
  # passing alone. The wait only bounds a failure; a passing render returns as soon as it can.
  @async_timeout 2_000
  @epoch 2
  @tree String.duplicate("e", 40)
  @sha1 String.duplicate("1", 40)
  @sha2 String.duplicate("2", 40)

  setup %{conn: conn} do
    {tenant, authenticator, session} = human()
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

    record =
      fixture(:intake_record, %{
        tenant_id: tenant.id,
        project_id: story.project_id,
        repo_full_name: "acme/widgets"
      })

    {:ok, _} =
      Repo.with_tenant(tenant.id, fn ->
        from(s in Source, where: s.id == ^record.source_id)
        |> Repo.update_all(set: [base_branch: "trunk"])
      end)

    {:ok,
     %{
       tenant: tenant,
       authenticator: authenticator,
       session: session,
       story: story,
       agent: agent,
       conn: signed_in(conn, session)
     }}
  end

  # A tenant, the authenticator its human enrolled, and a live session, on the RLS repo.
  defp human(session_attrs \\ %{}) do
    tenant = fixture(:stage_tenant, %{})
    auth = fixture(:root_authenticator, tenant_id: tenant.id, repo: Repo)

    session =
      fixture(
        :browser_session,
        Map.merge(%{tenant_id: tenant.id, authenticator_id: auth.id, repo: Repo}, session_attrs)
      )

    {tenant, auth, session}
  end

  defp signed_in(conn, session) do
    init_test_session(conn, %{
      BrowserAuth.session_key() => %{
        "tenant_id" => session.tenant_id,
        "session_id" => session.id
      }
    })
  end

  defp checkpoint(ctx, sha, epoch \\ @epoch) do
    {:ok, cp, :created} =
      Threads.record_checkpoint(ctx.tenant.id, ctx.story.id,
        agent_id: ctx.agent.id,
        claim_epoch: epoch,
        commit_sha: sha,
        tree_sha: @tree,
        note: "implemented the thing",
        author_principal: "agent:#{ctx.agent.id}",
        actor_lineage: []
      )

    cp
  end

  defp message(ctx, key, body) do
    {:ok, entry, :created} =
      Threads.record_entry(
        ctx.tenant.id,
        ctx.story.id,
        %{"kind" => "message", "idempotency_key" => key, "body" => body},
        author_principal: "agent:#{ctx.agent.id}",
        actor_lineage: []
      )

    entry
  end

  # The implement dispatch a claim was placed under, as the ledger records it once its runner
  # accepted it: what `DispatchPayload.dispatch_route/3` reads the placed base from.
  defp placed(ctx, runner, epoch, base_branch) do
    now = DateTime.utc_now()

    in_tenant(ctx, fn ->
      Repo.insert!(%Loopctl.Runners.DispatchRecord{
        tenant_id: ctx.tenant.id,
        runner_id: runner.id,
        dispatch_id: Ecto.UUID.generate(),
        story_id: ctx.story.id,
        claim_epoch: epoch,
        kind: "implement",
        mode: "thread",
        base_branch: base_branch,
        status: "accepted",
        wall_clock_seconds: 3_600,
        released_at: now,
        inserted_at: now,
        updated_at: now
      })
    end)
  end

  defp entries(ctx, kind) do
    {:ok, rows} =
      Repo.with_tenant(ctx.tenant.id, fn ->
        Repo.all(from e in Entry, where: e.story_id == ^ctx.story.id and e.kind == ^kind)
      end)

    rows
  end

  defp in_tenant(ctx, fun) do
    {:ok, result} = Repo.with_tenant(ctx.tenant.id, fun)
    result
  end

  defp open(ctx), do: live(ctx.conn, ~p"/threads/#{ctx.story.id}")

  defp nonce_of(view, form) do
    [_, value] =
      Regex.run(
        ~r/value="([^"]+)"/,
        view |> element("##{form}-form input[name='#{form}[nonce]']") |> render()
      )

    value
  end

  describe "the session guard (AC-45.7.1)" do
    test "an unauthenticated request is sent to /login, remembering the thread", ctx do
      conn = get(build_conn(), ~p"/threads/#{ctx.story.id}")
      assert redirected_to(conn) == ~p"/login"
      assert get_session(conn, "browser_return_to") == "/threads/#{ctx.story.id}"
    end

    test "an expired, a logged-out and a revoked-authenticator session are all refused",
         ctx do
      {_tenant, _auth, expired} = human(%{expires_at: DateTime.add(DateTime.utc_now(), -1)})
      assert redirected_to(get(signed_in(build_conn(), expired), ~p"/threads/x")) == ~p"/login"

      {_tenant, _auth, revoked} = human(%{revoked_at: DateTime.utc_now()})
      assert redirected_to(get(signed_in(build_conn(), revoked), ~p"/threads/x")) == ~p"/login"

      in_tenant(ctx, fn ->
        Repo.delete_all(from a in RootAuthenticator, where: a.id == ^ctx.authenticator.id)
      end)

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
      {_other, _auth, session} = human()

      {:ok, view, _html} =
        build_conn() |> signed_in(session) |> live(~p"/threads/#{ctx.story.id}")

      assert has_element?(view, "#thread-not-found")
      refute has_element?(view, "#thread-page")
    end

    test "a malformed thread id renders not-found and refuses crafted writes", ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/threads/not-a-uuid")
      assert has_element?(view, "#thread-not-found")

      render_hook(view, "post_message", %{"message" => %{"nonce" => "n", "body" => "b"}})

      render_hook(view, "post_finding", %{
        "finding" => %{"nonce" => "n", "body" => "b", "severity" => "high"}
      })

      render_hook(view, "load_diff", %{"id" => Ecto.UUID.generate()})
      assert has_element?(view, "#thread-not-found")
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

      message(ctx, "m1", "<script>alert(1)</script> **not bold**")
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

    test "a checkpoint's diff is against ITS claim's placed base; no placed base falls back, and says so",
         ctx do
      runner = fixture(:stage_runner, %{tenant_id: ctx.tenant.id})
      placed(ctx, runner, @epoch, "release-1")
      cp1 = checkpoint(ctx, @sha1)

      # The story is re-claimed; the new claim was placed on another base, and records a
      # checkpoint of its own. The first checkpoint is still judged against ITS claim's base.
      in_tenant(ctx, fn ->
        from(s in Story, where: s.id == ^ctx.story.id)
        |> Repo.update_all(set: [claim_epoch: @epoch + 1])
      end)

      placed(ctx, runner, @epoch + 1, "main")
      cp2 = checkpoint(ctx, @sha2, @epoch + 1)

      expect(Loopctl.MockPullRequestSource, :checkpoint_diff, fn %Loopctl.Delivery.ForgeRepo{
                                                                   full_name: "acme/widgets"
                                                                 },
                                                                 "release-1",
                                                                 @sha1 ->
        {:ok, %{text: "+first", truncated: false}}
      end)

      expect(Loopctl.MockPullRequestSource, :checkpoint_diff, fn %Loopctl.Delivery.ForgeRepo{
                                                                   full_name: "acme/widgets"
                                                                 },
                                                                 "main",
                                                                 @sha2 ->
        {:ok, %{text: "+second", truncated: false}}
      end)

      {:ok, view, _html} = open(ctx)

      view |> element("#diff-button-#{cp1.id}") |> render_click()
      render_async(view, @async_timeout)
      assert has_element?(view, "#diff-#{cp1.id}-base", "release-1")
      refute has_element?(view, "#diff-#{cp1.id}-base", "CURRENT base")

      view |> element("#diff-button-#{cp2.id}") |> render_click()
      render_async(view, @async_timeout)
      assert has_element?(view, "#diff-#{cp2.id}", "+second")
    end

    test "a claim with no ledger row is diffed against the source's current base, flagged",
         ctx do
      cp = checkpoint(ctx, @sha1)

      expect(Loopctl.MockPullRequestSource, :checkpoint_diff, fn %Loopctl.Delivery.ForgeRepo{
                                                                   full_name: "acme/widgets"
                                                                 },
                                                                 "trunk",
                                                                 @sha1 ->
        {:ok, %{text: "+fallback", truncated: false}}
      end)

      {:ok, view, _html} = open(ctx)
      view |> element("#diff-button-#{cp.id}") |> render_click()
      render_async(view, @async_timeout)

      assert has_element?(view, "#diff-#{cp.id}", "+fallback")
      assert has_element?(view, "#diff-#{cp.id}-base", "CURRENT base")
    end

    test "#936: with no credential for the repository the diff says so, and nothing is read",
         ctx do
      cp = checkpoint(ctx, @sha1)

      stub(Loopctl.MockVerificationCredential, :for_read, fn _tenant_id, "acme/widgets" ->
        {:error, :credential_unavailable}
      end)

      expect(Loopctl.MockPullRequestSource, :checkpoint_diff, 0, fn _repo, _base, _head ->
        {:ok, %{text: "+read anyway", truncated: false}}
      end)

      {:ok, view, _html} = open(ctx)
      view |> element("#diff-button-#{cp.id}") |> render_click()
      render_async(view, @async_timeout)

      assert has_element?(view, "#diff-#{cp.id}", "no GitHub credential for this repository")
    end

    test "one diff is open at a time; opening another closes it", ctx do
      cp1 = checkpoint(ctx, @sha1)
      cp2 = checkpoint(ctx, @sha2)

      stub(Loopctl.MockPullRequestSource, :checkpoint_diff, fn _repo, _base, head ->
        {:ok, %{text: "+of #{head}", truncated: false}}
      end)

      {:ok, view, _html} = open(ctx)
      view |> element("#diff-button-#{cp1.id}") |> render_click()
      render_async(view, @async_timeout)
      view |> element("#diff-button-#{cp2.id}") |> render_click()
      render_async(view, @async_timeout)

      assert has_element?(view, "#diff-#{cp2.id}", "+of #{@sha2}")
      refute has_element?(view, "#diff-#{cp1.id}")
      assert has_element?(view, "#diff-button-#{cp1.id}")
    end

    test "only this page's checkpoints are fetched, and an open diff is not fetched again",
         ctx do
      cp = checkpoint(ctx, @sha1)

      expect(Loopctl.MockPullRequestSource, :checkpoint_diff, 1, fn _repo, _base, _head ->
        {:ok, %{text: "+once", truncated: false}}
      end)

      {:ok, view, _html} = open(ctx)
      render_hook(view, "load_diff", %{"id" => Ecto.UUID.generate()})
      render_async(view, @async_timeout)
      # Nothing was opened for an id this page does not show.
      assert :sys.get_state(view.pid).socket.assigns.open_diff == nil

      view |> element("#diff-button-#{cp.id}") |> render_click()
      render_async(view, @async_timeout)
      render_hook(view, "load_diff", %{"id" => cp.id})
      render_async(view, @async_timeout)

      assert has_element?(view, "#diff-#{cp.id}", "+once")
    end

    test "a slow forge leaves the ledger rendered; a down one offers a retry", ctx do
      cp = checkpoint(ctx, @sha1)
      test_pid = self()

      expect(Loopctl.MockPullRequestSource, :checkpoint_diff, fn _repo, "trunk", @sha1 ->
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
      render_async(view, @async_timeout)
      assert has_element?(view, "#diff-#{cp.id}", "did not answer")

      expect(Loopctl.MockPullRequestSource, :checkpoint_diff, fn _repo, "trunk", @sha1 ->
        {:ok, %{text: "+second time", truncated: false}}
      end)

      view |> element("#diff-#{cp.id}-retry") |> render_click()
      render_async(view, @async_timeout)
      assert has_element?(view, "#diff-#{cp.id}", "+second time")
    end

    test "the page opens on the NEWEST entries and walks backwards", ctx do
      checkpoint(ctx, @sha1)

      for n <- 1..(Threads.max_entry_page() + 5),
          do: message(ctx, "m#{n}", "message number #{n}")

      last = Threads.max_entry_page() + 5
      {:ok, view, _html} = open(ctx)

      assert has_element?(view, "#thread-entries pre", "message number #{last}")
      refute has_element?(view, "#thread-entries pre", "implemented the thing")

      view |> element("#thread-load-older") |> render_click()
      assert has_element?(view, "#thread-entries pre", "implemented the thing")
      refute has_element?(view, "#thread-load-older")
    end
  end

  describe "the finding form binds only to the current claim" do
    defp reclaim(ctx, epoch) do
      in_tenant(ctx, fn ->
        from(s in Story, where: s.id == ^ctx.story.id)
        |> Repo.update_all(set: [claim_epoch: epoch])
      end)
    end

    defp checkpoint_options(view) do
      view
      |> element("#finding-checkpoint")
      |> render()
      |> then(&Regex.scan(~r/value="([^"]+)"/, &1))
      |> Enum.map(fn [_, id] -> id end)
    end

    test "only the current claim's checkpoints are offered, refreshed on the tick", ctx do
      old = checkpoint(ctx, @sha1)
      {:ok, view, _html} = open(ctx)
      assert checkpoint_options(view) == [old.id]

      # Re-claimed, and the new claim records a checkpoint while the page is open.
      reclaim(ctx, @epoch + 1)
      new = checkpoint(ctx, @sha2, @epoch + 1)
      send(view.pid, :revalidate)

      assert checkpoint_options(view) == [new.id]

      assert has_element?(
               view,
               "#finding-checkpoint option[selected]",
               String.slice(@sha2, 0, 12)
             )

      # The diff allow-list followed the refresh.
      assert has_element?(view, "#diff-button-#{new.id}")
    end

    test "a claim with no checkpoint disables the form and says why", ctx do
      checkpoint(ctx, @sha1)
      reclaim(ctx, @epoch + 1)
      {:ok, view, _html} = open(ctx)

      assert has_element?(view, "#finding-unavailable")
      assert has_element?(view, "#finding-form fieldset[disabled]")
      assert checkpoint_options(view) == []
    end

    test "a write refreshes the checkpoints too", ctx do
      checkpoint(ctx, @sha1)
      {:ok, view, _html} = open(ctx)
      new = checkpoint(ctx, @sha2)

      view |> form("#message-form") |> render_submit(%{message: %{body: "hi"}})
      assert new.id in checkpoint_options(view)
    end
  end

  describe "writing (TC-45.7.3)" do
    test "a resubmit after a reconnect carries the first submit's nonce: one entry", ctx do
      checkpoint(ctx, @sha1)
      {:ok, first, _html} = open(ctx)
      nonce = nonce_of(first, "message")

      # The write lands, but the page never hears back and reconnects: a fresh mount, which
      # mints a fresh nonce.
      first |> form("#message-form") |> render_submit(%{message: %{body: "only once"}})
      {:ok, again, _html} = open(ctx)
      refute nonce_of(again, "message") == nonce

      # Form recovery sends the pre-reconnect values as a change; the resubmit carries them.
      again
      |> form("#message-form")
      |> render_change(%{message: %{body: "only once", nonce: nonce}})

      again |> form("#message-form") |> render_submit()

      assert [_one] = entries(ctx, :message)
    end

    test "a malformed recovered nonce is not adopted", ctx do
      checkpoint(ctx, @sha1)
      {:ok, view, _html} = open(ctx)
      minted = nonce_of(view, "message")

      view |> form("#message-form") |> render_change(%{message: %{body: "x", nonce: "short"}})
      assert nonce_of(view, "message") == minted
    end

    test "the same message form submitted twice is one entry, the human's, with no lineage",
         ctx do
      checkpoint(ctx, @sha1)
      {:ok, view, _html} = open(ctx)

      nonce = nonce_of(view, "message")
      params = %{message: %{body: "looks right to me", nonce: nonce}}

      view |> form("#message-form") |> render_submit(params)
      view |> form("#message-form") |> render_submit(params)

      assert [message] = entries(ctx, :message)
      assert message.idempotency_key == nonce
      assert message.author_principal == "human:webauthn"
      assert message.dispatch_id == nil
      assert has_element?(view, "#message-notice", "Recorded")
      assert has_element?(view, "#entry-#{message.id}", "looks right to me")
    end

    test "a write adds its entry without re-reading the ledger", ctx do
      cp = checkpoint(ctx, @sha1)

      expect(Loopctl.MockPullRequestSource, :checkpoint_diff, fn _repo, _base, _head ->
        {:ok, %{text: "+kept", truncated: false}}
      end)

      {:ok, view, _html} = open(ctx)
      view |> element("#diff-button-#{cp.id}") |> render_click()
      render_async(view, @async_timeout)

      # Written behind the page's back: a write that re-read the thread would show it.
      message(ctx, "behind", "written elsewhere")

      view
      |> form("#message-form")
      |> render_submit(%{message: %{nonce: "n1", body: "mine"}})

      assert has_element?(view, "#thread-entries pre", "mine")
      refute has_element?(view, "#thread-entries pre", "written elsewhere")
      assert has_element?(view, "#diff-#{cp.id}", "+kept")
    end

    test "a finding form submitted twice is one finding, bound to the checkpoint", ctx do
      cp = checkpoint(ctx, @sha1)
      {:ok, view, _html} = open(ctx)

      params = %{
        finding: %{
          nonce: nonce_of(view, "finding"),
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

    test "a material finding after the final verdict escalates, and the page says so", ctx do
      orchestrator = fixture(:stage_agent, %{tenant_id: ctx.tenant.id})
      reviewer = fixture(:stage_agent, %{tenant_id: ctx.tenant.id})
      root = fixture(:stage_dispatch, %{tenant_id: ctx.tenant.id, agent_id: orchestrator.id})

      session =
        fixture(:stage_dispatch, %{tenant_id: ctx.tenant.id, agent_id: ctx.agent.id, parent: root})

      in_tenant(ctx, fn ->
        from(s in Story, where: s.id == ^ctx.story.id)
        |> Repo.update_all(set: [implementer_dispatch_id: session.id])
      end)

      round = fn ->
        {:ok, review, :created} =
          Threads.record_review(ctx.tenant.id, ctx.story.id,
            dispatch_id: Ecto.UUID.generate(),
            runner_id: reviewer.id,
            agent_id: reviewer.id,
            placed_by: "api_key:test"
          )

        {:ok, _, :created} =
          Threads.record_judgement(
            ctx.tenant.id,
            ctx.story.id,
            review.dispatch_id,
            %{"kind" => "verdict", "idempotency_key" => "v-#{review.id}", "body" => "done"},
            runner_id: reviewer.id,
            author_principal: "agent:#{reviewer.id}"
          )
      end

      checkpoint(ctx, @sha1)
      round.()
      cp2 = checkpoint(ctx, @sha2)
      round.()

      stage =
        fixture(:story_stage, %{
          tenant_id: ctx.tenant.id,
          story_id: ctx.story.id,
          stage: :reviewing,
          claim_epoch: @epoch
        })

      {:ok, view, _html} = open(ctx)

      view
      |> form("#finding-form")
      |> render_submit(%{
        finding: %{
          nonce: "late",
          checkpoint_id: cp2.id,
          severity: "critical",
          introduced_by: "none",
          body: "found after the last round"
        }
      })

      assert has_element?(view, "#finding-notice", "escalated the story")
      assert [escalation] = entries(ctx, :escalation)
      assert has_element?(view, "#entry-#{escalation.id}", "review_ceiling")

      # A second late finding is told the story was ALREADY escalated, and moves nothing.
      view
      |> form("#finding-form")
      |> render_submit(%{
        finding: %{
          nonce: "later",
          checkpoint_id: cp2.id,
          severity: "high",
          introduced_by: "none",
          body: "another after the last round"
        }
      })

      assert has_element?(view, "#finding-notice", "already escalated")
      assert [_one] = entries(ctx, :escalation)

      # The stage moved at once: the page enqueued the move (Oban runs inline here).
      assert %{stage: :escalated} =
               in_tenant(ctx, fn -> Repo.get(Loopctl.Delivery.StoryStage, stage.id) end)
    end

    test "a revoked authenticator refuses an open page's next write", ctx do
      checkpoint(ctx, @sha1)
      {:ok, view, _html} = open(ctx)

      in_tenant(ctx, fn ->
        Repo.delete_all(from a in RootAuthenticator, where: a.id == ^ctx.authenticator.id)
      end)

      assert {:error, {:redirect, %{to: "/login"}}} =
               view
               |> form("#message-form")
               |> render_submit(%{message: %{nonce: "m1", body: "after revoke"}})

      assert [] == entries(ctx, :message)
    end

    test "a logout elsewhere signs an idle page out on its timer", ctx do
      checkpoint(ctx, @sha1)
      {:ok, view, _html} = open(ctx)

      in_tenant(ctx, fn ->
        from(s in BrowserSession, where: s.id == ^ctx.session.id)
        |> Repo.update_all(set: [revoked_at: DateTime.utc_now()])
      end)

      send(view.pid, :revalidate)
      assert_redirect(view, "/login")
    end
  end

  test "the session value names the row and its tenant, nothing else", ctx do
    assert BrowserLogin.to_session(%{
             tenant_id: ctx.tenant.id,
             session_id: ctx.session.id,
             authenticator_id: ctx.authenticator.id,
             authenticated_at: DateTime.utc_now()
           }) == %{"tenant_id" => ctx.tenant.id, "session_id" => ctx.session.id}
  end
end
