defmodule LoopctlWeb.RequireHumanAnchorDefaultDenyTest do
  @moduledoc """
  US-26.7.1 / AC-26.7.1.9 (TC-26.7.1.4) — DEFAULT-DENY GUARD TEST.

  Walks `LoopctlWeb.Router.__routes__/0`, keeps every route on the
  `:authenticated` pipeline whose method mutates (POST/PUT/PATCH/DELETE),
  SUBTRACTS an explicit, reviewed KB-tier/account/superadmin allowlist, and
  asserts that EVERY remaining route returns `403 custody_tier_required`
  when called by an agent-rooted tenant — using a role-appropriate key for
  that specific route (some routes gate on `exact_role`, which a plain
  `:user` key does not satisfy; those are looked up in `@role_overrides` and
  called with the matching role instead, so the assertion isolates the tier
  gate from the role gate per TC-26.7.1.4).

  This is the authoritative check that AC-26.7.1.7's per-controller
  enumeration is complete: a wrong/missing action atom compiles to a silent
  no-op guard with NO other symptom, so this test is the only thing that
  would catch it. Any NEW custody route added later that is neither gated
  nor allowlisted here FAILS this test — the surface fails closed.
  """

  use LoopctlWeb.ConnCase, async: true

  setup :verify_on_exit!

  # {verb, path} pairs deliberately NOT tier-gated. Every group has a
  # one-line reason. Anything NOT in this set (still on the `:authenticated`
  # pipeline, with a mutating verb) is asserted to 403 below.
  @allowlist MapSet.new([
               # Tenant self-management + BYO LLM config — account-neutral, not custody.
               {:patch, "/api/v1/tenants/me"},
               {:patch, "/api/v1/tenants/me/llm-config"},
               # rotate-audit-key (challenge + rotate) is gated by a FRESH
               # per-op WebAuthn assertion (WebAuthn.Reauth) + tenant ownership,
               # a STRONGER control than the tier gate — an agent-rooted tenant
               # has no enrolled authenticator, so `challenge` 422s
               # (no_authenticators) and `rotate` can never produce a valid
               # assertion. No tier gate needed.
               {:post, "/api/v1/tenants/:id/rotate-audit-key/challenge"},
               {:post, "/api/v1/tenants/:id/rotate-audit-key"},
               # bootstrap-audit-key (#5 reviewed rationale): UNREACHABLE, not
               # tier-relevant. BOTH signup paths (signup/1 and self_signup/1)
               # mandatorily pre-provision the audit key, so `bootstrap` 409s
               # `key_already_exists` for every current and future tenant. The
               # `always_has_audit_key` regression test (signup_test.exs) guards
               # that precondition so this exemption can't silently rot if
               # provisioning ever became lazy.
               {:post, "/api/v1/tenants/:id/bootstrap-audit-key"},

               # US-26.7.2 — opt-in WebAuthn trust-tier upgrade ceremony. `challenge`
               # and `create` ARE the upgrade path itself: an agent-rooted caller
               # (zero authenticators) is the INTENDED audience for a first
               # enrollment, so gating them behind RequireHumanAnchor would make the
               # tier unreachable from the tier it's meant to lift a tenant out of.
               # A SUBSEQUENT (backup) enrollment on an already-human_anchored tenant
               # is instead gated by a FRESH `add_authenticator` WebAuthn assertion
               # from an existing authenticator (Loopctl.WebAuthn.Reauth) — a
               # STRONGER control than the tier gate, since a stolen role:user key
               # alone can never satisfy it (AC-26.7.2.3's critical
               # anti-soft-recovery-backdoor gate). `revoke-challenge` + the DELETE
               # are likewise gated by a fresh `revoke_authenticator` assertion, not
               # the tier — mirroring rotate-audit-key's exemption above.
               {:post, "/api/v1/tenants/:id/authenticators/challenge"},
               {:post, "/api/v1/tenants/:id/authenticators"},
               {:post, "/api/v1/tenants/:id/authenticators/revoke-challenge"},
               {:delete, "/api/v1/tenants/:id/authenticators/:auth_id"},

               # /api_keys management — explicitly excluded (AC-26.7.1.7).
               {:post, "/api/v1/api_keys"},
               {:delete, "/api/v1/api_keys/:id"},
               {:post, "/api/v1/api_keys/:id/rotate"},

               # Agent's own identity — explicitly excluded (AC-26.7.1.7/.8).
               {:post, "/api/v1/agents/register"},

               # Knowledge/article/wiki/article_link — full KB-tier surface,
               # explicitly excluded (AC-26.7.1.7).
               {:post, "/api/v1/articles"},
               {:put, "/api/v1/articles/:id"},
               {:patch, "/api/v1/articles/:id"},
               {:delete, "/api/v1/articles/:id"},
               {:post, "/api/v1/articles/:id/publish"},
               {:post, "/api/v1/articles/:id/unpublish"},
               {:post, "/api/v1/articles/:id/archive"},
               {:post, "/api/v1/knowledge/bulk-publish"},
               {:post, "/api/v1/knowledge/bulk-unpublish"},
               {:post, "/api/v1/knowledge/bulk-delete"},
               {:post, "/api/v1/knowledge/conflicts/resolve"},
               {:post, "/api/v1/knowledge/novelty"},
               # Hybrid retrieval (US-31.4) — a POST-shaped READ over the wiki
               # (curated-first, retrieval-fallback resolution with provenance),
               # NOT a mutation. It surfaces `Knowledge.hybrid_search/3`, is
               # role: agent+ (mirroring GET /knowledge/search), and is
               # tenant-scoped from the key — part of the KB-tier read surface an
               # agent-rooted tenant is the intended user of. POST (vs GET) only
               # because it carries a richer JSON body.
               {:post, "/api/v1/knowledge/hybrid_search"},
               {:post, "/api/v1/knowledge/okf/import"},
               {:post, "/api/v1/knowledge/ingest"},
               {:post, "/api/v1/knowledge/ingest/batch"},
               {:post, "/api/v1/projects/:project_id/articles"},
               {:post, "/api/v1/article_links"},
               {:delete, "/api/v1/article_links/:id"},

               # Agent Memory (Epic 28, US-28.3) — the agent's own per-subject
               # working memory, part of the KB-tier agent surface alongside the
               # Knowledge/article routes above. An agent-rooted (KB-tier) tenant
               # is the INTENDED user of agent memory, so gating it behind
               # human-anchor would make the feature unreachable for the very tier
               # it's built for. Isolation is the (tenant_id, subject_id) boundary
               # (derived from the key, never the body); own-memory delete is
               # subject-scoped and the tenant-wide (any-subject) list/delete
               # oversight path is superadmin-only. recall is a POST-shaped READ.
               # promote (US-29.3) triggers the agent's own session→long-term
               # promotion — same KB-tier agent surface, same (tenant, subject)
               # key-derived scope, so it is allowlisted alongside its siblings.
               {:post, "/api/v1/memory"},
               {:post, "/api/v1/memory/recall"},
               {:post, "/api/v1/memory/promote"},
               {:delete, "/api/v1/memory/:id"},

               # Context Retriever (Epic 30, US-30.4) — `POST /retrieve/:entity` is a
               # POST-shaped READ (a governed filter/search over the tenant's OWN
               # structured records), NOT a mutation. Querying is the floor-agent /
               # KB-tier surface (AC-30.4.2), so gating it behind human-anchor would
               # make an agent-rooted tenant unable to query its own data — the
               # opposite of intent. The executor dual tenant-scopes every read (RLS +
               # explicit predicate) and re-validates the field against the SERVER
               # allowlist, so no data crosses tenants. DEFINING/mutating an entity
               # definition (POST/PATCH/DELETE /entities) IS tier-gated — see
               # ContextRetrieverController's RequireHumanAnchor plug — so those routes
               # are (correctly) absent from this allowlist and asserted to 403.
               {:post, "/api/v1/retrieve/:entity"},

               # UI test runs (#4/#5 reviewed rationale): a QA/tooling surface,
               # NOT work-breakdown state. Every route is nested under
               # `/projects/:project_id/...` and creating a project
               # (`ProjectController.create`) is ALREADY tier-gated, so an
               # agent-rooted tenant has no project to attach a UI test to —
               # the surface is unreachable for it even without a per-route gate.
               {:post, "/api/v1/projects/:project_id/ui-tests"},
               {:post, "/api/v1/projects/:project_id/ui-tests/:id/findings"},
               {:post, "/api/v1/projects/:project_id/ui-tests/:id/complete"},

               # Webhooks (#4/#5 reviewed rationale): tenant-account integration
               # config (delivery endpoints), NOT custody state — analogous to
               # BYO LLM config, which is deliberately KB-tier-open. The SSRF
               # blast radius is independently bounded by `UrlGuard.pin` (egress
               # allowlist + DNS-rebinding defense) regardless of tier, so a
               # KB-tier tenant configuring a webhook cannot reach internal hosts.
               {:post, "/api/v1/webhooks"},
               {:put, "/api/v1/webhooks/:id"},
               {:patch, "/api/v1/webhooks/:id"},
               {:delete, "/api/v1/webhooks/:id"},
               {:post, "/api/v1/webhooks/:id/test"},

               # Superadmin-only admin scope — RequireRole already pins these
               # to superadmin; Impersonate explicitly skips
               # /api/v1/admin/*, so current_tenant is always nil
               # (superadmin) there — the tier gate doesn't apply and isn't
               # attached to these controllers.
               {:patch, "/api/v1/admin/tenants/:id"},
               {:post, "/api/v1/admin/tenants/:id/suspend"},
               {:post, "/api/v1/admin/tenants/:id/activate"},
               {:post, "/api/v1/admin/violators/:id/resolve"},
               {:post, "/api/v1/admin/violators/:id/ignore"},
               {:post, "/api/v1/admin/tenants/:id/clear-halt"}
             ])

  # Routes gated by `exact_role:` (not hierarchy) that a plain `:user` key
  # does not satisfy — mapped to the role that DOES, so the request reaches
  # (and is blocked by) the tier gate rather than the role gate first.
  @role_overrides %{
    {:post, "/api/v1/stories/:id/contract"} => :agent,
    {:post, "/api/v1/stories/:id/claim"} => :agent,
    {:post, "/api/v1/stories/:id/start"} => :agent,
    {:post, "/api/v1/stories/:id/request-review"} => :agent,
    {:post, "/api/v1/stories/:id/report"} => :agent,
    {:post, "/api/v1/stories/:id/unclaim"} => :agent,
    {:post, "/api/v1/stories/:id/report-done"} => :agent,
    {:post, "/api/v1/stories/:id/start-work"} => :agent,
    {:post, "/api/v1/stories/:id/recover-cap"} => :agent,
    {:post, "/api/v1/stories/bulk/claim"} => :agent,
    {:post, "/api/v1/stories/:id/artifacts"} => :agent,
    {:post, "/api/v1/stories/:id/verify"} => :orchestrator,
    {:post, "/api/v1/stories/:id/reject"} => :orchestrator,
    {:post, "/api/v1/stories/:id/force-unclaim"} => :orchestrator,
    {:post, "/api/v1/epics/:id/verify-all"} => :orchestrator,
    {:post, "/api/v1/stories/bulk/verify"} => :orchestrator,
    {:post, "/api/v1/stories/bulk/reject"} => :orchestrator,
    {:post, "/api/v1/stories/bulk/mark-complete"} => :orchestrator,
    {:put, "/api/v1/orchestrator/state/:project_id"} => :orchestrator,
    {:post, "/api/v1/skill_results"} => :orchestrator
  }

  test "every non-allowlisted authenticated mutating route 403s for an agent-rooted tenant" do
    tenant = fixture(:tenant, %{trust_tier: :agent_rooted})
    {user_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
    {orch_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})
    {agent_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

    keys = %{user: user_key, orchestrator: orch_key, agent: agent_key}

    # `LoopctlWeb.Router.__routes__/0` deliberately does NOT expose
    # `:pipe_through` (Phoenix.Router only keeps [:verb, :path, :plug,
    # :plug_opts, :helper, :metadata] there) — so pipeline membership is
    # resolved per-route via `Phoenix.Router.route_info/4`, which DOES
    # surface `:pipe_through` in its metadata map (confirmed against a live
    # match — it calls the router's own generated `__match_route__/3`).
    routes =
      LoopctlWeb.Router.__routes__()
      |> Enum.filter(fn route ->
        route.verb in [:post, :put, :patch, :delete] and authenticated_route?(route)
      end)

    assert length(routes) > 40,
           "sanity check: expected dozens of authenticated mutating routes, found #{length(routes)}"

    checked =
      Enum.reject(routes, fn route -> MapSet.member?(@allowlist, {route.verb, route.path}) end)

    # Includes representative routes from EVERY gated controller group
    # (AC-26.7.1.12b), explicitly named per TC-26.7.1.4.
    checked_pairs = Enum.map(checked, &{&1.verb, &1.path})
    assert {:post, "/api/v1/projects/:project_id/stories"} in checked_pairs
    assert {:post, "/api/v1/stories/bulk/verify"} in checked_pairs
    assert {:post, "/api/v1/stories/:id/recover-cap"} in checked_pairs
    assert {:post, "/api/v1/projects/:id/import"} in checked_pairs

    assert checked != [], "sanity check: there should be routes left to assert against"

    for route <- checked do
      role = Map.get(@role_overrides, {route.verb, route.path}, :user)
      raw_key = Map.fetch!(keys, role)
      path = substitute_params(route.path)

      conn =
        build_conn()
        |> put_req_header("x-loopctl-last-known-sth", "0:AAAAAAAAAAAAAAAAAAAAAA")
        |> put_req_header("authorization", "Bearer #{raw_key}")
        |> dispatch_verb(route.verb, path)

      assert conn.status == 403,
             "expected 403 for #{route.verb} #{route.path} (role=#{role}), " <>
               "got #{conn.status}: #{conn.resp_body}"

      body = Jason.decode!(conn.resp_body)

      assert body["error"]["code"] == "custody_tier_required",
             "expected custody_tier_required for #{route.verb} #{route.path}, " <>
               "got: #{inspect(body)}"
    end
  end

  defp substitute_params(path) do
    path
    |> String.split("/")
    |> Enum.map_join("/", fn
      ":" <> _param -> Ecto.UUID.generate()
      segment -> segment
    end)
  end

  defp authenticated_route?(route) do
    method = route.verb |> Atom.to_string() |> String.upcase()
    path = substitute_params(route.path)

    case Phoenix.Router.route_info(LoopctlWeb.Router, method, path, "localhost") do
      %{pipe_through: pipe_through} -> :authenticated in pipe_through
      _ -> false
    end
  end

  defp dispatch_verb(conn, :post, path), do: Phoenix.ConnTest.post(conn, path, %{})
  defp dispatch_verb(conn, :put, path), do: Phoenix.ConnTest.put(conn, path, %{})
  defp dispatch_verb(conn, :patch, path), do: Phoenix.ConnTest.patch(conn, path, %{})
  defp dispatch_verb(conn, :delete, path), do: Phoenix.ConnTest.delete(conn, path)
end
