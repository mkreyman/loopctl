defmodule LoopctlWeb.ChgLiveTest do
  @moduledoc """
  US-50.5 (TC-50.5.1..3): the chg dashboard. Seeds ledger rows, a review outcome and a flagged
  cursor on `AdminRepo` and reads them back through `Loopctl.HeavyRead` (on `AdminRepo` in
  test), so it runs async.
  """

  use LoopctlWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Loopctl.AdminRepo
  alias Loopctl.Changes.Cursor
  alias Loopctl.Changes.Events
  alias Loopctl.Changes.LedgerRow
  alias Loopctl.Changes.PrReviewOutcomes
  alias LoopctlWeb.BrowserAuth

  setup :verify_on_exit!

  defp operator(conn, tenant_id) do
    authenticator = fixture(:root_authenticator, tenant_id: tenant_id)
    session = fixture(:browser_session, tenant_id: tenant_id, authenticator_id: authenticator.id)

    init_test_session(conn, %{
      BrowserAuth.session_key() => %{"tenant_id" => tenant_id, "session_id" => session.id}
    })
  end

  defp row!(source, attrs) do
    repo = Events.repo_key(source.repo_full_name)
    raw = Map.merge(%{"v" => 1, "repo" => repo}, attrs.raw)

    AdminRepo.insert!(%LedgerRow{
      tenant_id: source.tenant_id,
      source_id: source.id,
      repo: repo,
      host: attrs.host,
      kind: attrs.kind,
      sha: attrs[:sha],
      verdict: attrs[:verdict],
      ms: attrs[:ms],
      at: DateTime.add(DateTime.utc_now(), -3600),
      raw: Map.put(raw, "kind", attrs.kind),
      row_hash: Ecto.UUID.generate()
    })
  end

  defp seed!(source) do
    s1 = String.duplicate("1", 40)
    s2 = String.duplicate("2", 40)

    row!(source, %{
      kind: "chg",
      host: "minis",
      sha: s1,
      verdict: "pass",
      ms: 900,
      raw: %{
        "mode" => "affected",
        "selected" => ["a_test.exs", "b_test.exs"],
        "floor" => 1,
        "hydrate_ms" => 10,
        "tests_ms" => 800
      }
    })

    row!(source, %{
      kind: "chg",
      host: "x1",
      sha: s2,
      verdict: "pass",
      ms: 5000,
      raw: %{"mode" => "all", "selection" => "mix.lock changed", "hydrate_ms" => 30}
    })

    row!(source, %{kind: "gate", host: "minis", sha: s1, verdict: "fail", ms: 1000, raw: %{}})
    # s2's chg check ran `mode = all` and passed where the gate failed: NOT a miss, since it
    # selected nothing out.
    row!(source, %{kind: "gate", host: "x1", sha: s2, verdict: "fail", ms: 6000, raw: %{}})

    row!(source, %{
      kind: "flaky",
      host: "minis",
      raw: %{"test" => "Loopctl.FooTest: test races", "quarantine" => "q-17"}
    })

    row!(source, %{kind: "runner", host: "x1", ms: 42, raw: %{"load" => "0.5"}})

    {:ok, _} =
      PrReviewOutcomes.record(source, 9, %{
        body: "no findings section here",
        merged_at: DateTime.utc_now(),
        merge_sha: String.duplicate("c", 40)
      })

    AdminRepo.insert!(%Cursor{
      tenant_id: source.tenant_id,
      source_id: source.id,
      repo: Events.repo_key(source.repo_full_name),
      change_id: "CHG-GAP-1",
      applied_seq: 3,
      last_event_at: DateTime.utc_now(),
      attention: "gap",
      attention_at: DateTime.utc_now()
    })

    %{s1: s1, s2: s2, repo: Events.repo_key(source.repo_full_name)}
  end

  describe "TC-50.5.1: unauthenticated is redirected" do
    test "GET /chg with no session goes to the login page", %{conn: conn} do
      assert redirected_to(get(conn, ~p"/chg")) == ~p"/login"
    end

    test "an expired or revoked session is refused too", %{conn: conn} do
      tenant = fixture(:tenant)
      authenticator = fixture(:root_authenticator, tenant_id: tenant.id)

      for attrs <- [
            %{expires_at: DateTime.add(DateTime.utc_now(), -1)},
            %{revoked_at: DateTime.utc_now()}
          ] do
        session =
          fixture(
            :browser_session,
            Map.merge(attrs, %{tenant_id: tenant.id, authenticator_id: authenticator.id})
          )

        conn =
          init_test_session(conn, %{
            BrowserAuth.session_key() => %{"tenant_id" => tenant.id, "session_id" => session.id}
          })

        assert redirected_to(get(conn, ~p"/chg")) == ~p"/login"
      end
    end

    test "the live mount refuses a socket whose session is gone", %{conn: conn} do
      tenant = fixture(:tenant)
      conn = operator(conn, tenant.id)
      {:ok, view, _html} = live(conn, ~p"/chg")

      %{"session_id" => sid} = get_session(conn, BrowserAuth.session_key())

      AdminRepo.update_all(
        from(s in Loopctl.WebAuthn.BrowserSession, where: s.id == ^sid),
        set: [revoked_at: DateTime.utc_now()]
      )

      send(view.pid, :revalidate)
      assert_redirect(view, ~p"/login")
    end
  end

  describe "TC-50.5.2: panels render from seeded rows" do
    setup %{conn: conn} do
      {_secret, source} = fixture(:intake_source, %{})
      seeded = seed!(source)
      %{conn: operator(conn, source.tenant_id), seeded: seeded}
    end

    test "each panel has its element and counts matching the seed", %{conn: conn, seeded: s} do
      {:ok, view, _html} = live(conn, ~p"/chg")

      for id <- ~w(panel-gate-outcomes panel-fallbacks panel-selection panel-phases panel-flaky
                   panel-runner panel-reviews panel-attention) do
        assert has_element?(view, "##{id}")
      end

      day = DateTime.utc_now() |> DateTime.add(-3600) |> DateTime.to_date() |> to_string()

      assert has_element?(view, "#gate-outcome-#{day}-chg")
      assert has_element?(view, "#gate-outcome-#{day}-gate")

      assert has_element?(view, "#fallback-rate", "50.0%")
      assert has_element?(view, "#fallback-reasons", "mix.lock changed")

      assert has_element?(view, "#selection-checks", "1")
      assert has_element?(view, "#selection-misses", String.slice(s.s1, 0, 12))
      refute has_element?(view, "#selection-misses", String.slice(s.s2, 0, 12))

      assert has_element?(view, "#phase-hydrate_ms")
      assert has_element?(view, "#phase-tests_ms")
      refute has_element?(view, "#phase-lock_wait_ms")

      assert has_element?(view, "#flaky-list", "Loopctl.FooTest: test races")
      assert has_element?(view, "#flaky-list", "quarantine q-17")
      assert has_element?(view, "#runner-list", "load=0.5")

      outcome_id = LoopctlWeb.ChgLive.outcome_dom_id(%{repo: s.repo, pr_number: 9})
      assert outcome_id =~ ~r/\Aoutcome-[a-f0-9]+-9\z/

      refute LoopctlWeb.ChgLive.outcome_dom_id(%{repo: "a/b-c", pr_number: 1}) ==
               LoopctlWeb.ChgLive.outcome_dom_id(%{repo: "a-b/c", pr_number: 1})

      assert has_element?(view, "##{outcome_id}", "no counted round")
      assert has_element?(view, "#reviews-without-round", "1")

      assert has_element?(view, "#attention-list", "CHG-GAP-1")
    end

    test "filtering by host narrows the counts", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/chg")

      view
      |> form("#chg-filters", filter: %{host: "minis", repo: "", period: "7d"})
      |> render_change()

      assert_patch(view, ~p"/chg?#{%{host: "minis", period: "7d"}}")

      assert has_element?(view, "#fallback-rate", "0.0%")
      refute has_element?(view, "#fallback-reasons")
      assert has_element?(view, "#flaky-list", "Loopctl.FooTest")
      refute has_element?(view, "#runner-list", "load=0.5")
      assert has_element?(view, "#runner-list", "No runner samples")
    end

    test "a host the page does not offer is ignored rather than trusted", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/chg?host=nowhere")
      assert has_element?(view, "#fallback-rate", "50.0%")
    end
  end

  describe "TC-50.5.3: tenant isolation" do
    test "an operator of tenant B sees only empty states over tenant A's rows", %{conn: conn} do
      {_secret, source} = fixture(:intake_source, %{})
      seed!(source)

      tenant_b = fixture(:tenant)
      {:ok, view, _html} = live(operator(conn, tenant_b.id), ~p"/chg")

      assert has_element?(view, "#panel-gate-outcomes .empty-state")
      assert has_element?(view, "#panel-fallbacks .empty-state")
      assert has_element?(view, "#panel-selection .empty-state")
      assert has_element?(view, "#panel-phases .empty-state")
      assert has_element?(view, "#flaky-list", "No flaky tests")
      assert has_element?(view, "#runner-list", "No runner samples")
      assert has_element?(view, "#review-outcomes", "No merged PRs")
      assert has_element?(view, "#attention-list", "No change is flagged")

      # Each list's empty <li> is always in the DOM (shown by CSS when it is the only child), so
      # the empty text alone proves nothing: no OTHER row may be present.
      for {list, empty} <- [
            {"flaky-list", "flaky-empty"},
            {"runner-list", "runner-empty"},
            {"review-outcomes", "outcomes-empty"},
            {"attention-list", "attention-empty"}
          ] do
        refute has_element?(view, "##{list} > li:not(##{empty})"), "#{list} has a row"
      end

      refute render(view) =~ "CHG-GAP-1"
      refute render(view) =~ source.tenant_id
    end
  end
end
