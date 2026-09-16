/**
 * EVERY `/api/v1` ROUTE A SESSION IS MEANT TO USE MUST BE REACHABLE BY AN MCP TOOL, OR BE
 * DECLARED HERE WITH A REASON (loopctl #846.6, AC-3).
 *
 * ## WHY A SWEEP AND NOT A THIRD PER-DEFECT TEST
 *
 * One evening, 2026-09-15, produced three instances of one rule being broken —
 * `force_unclaim_story` had no tool (#846.3), `place_dispatch` omitted a parameter its own
 * refusal demanded (#846.5), and `PATCH /api/v1/stories/:id` had no tool at all (#846.6). The
 * rule is loopctl's own: an operator-facing endpoint is not done until an MCP tool calls it,
 * and it is load-bearing rather than tidy, because `claude-config`'s
 * `hooks/orchestrator-guardrail.sh` refuses a `curl` carrying `loopctl.com` from any session.
 * An endpoint with no tool is reachable by a human with `iex` on the production node and by
 * nothing else.
 *
 * Three misses on one workflow in one evening is a systematic gap, and a per-defect test
 * cannot find the fourth. This is the sweep that can.
 *
 * ## WHAT IT ACTUALLY PROVES, AND WHAT IT DOES NOT
 *
 * `reachedRoutes()` (`test/tool-surface.js`) resolves every `apiCall`/`publicApiCall` site in
 * the files npm SHIPS — `index.js` plus `lib/` — to the `VERB /path` it sends, normalising ids
 * to `:param`. `routerRoutes()` parses `lib/loopctl_web/router.ex` for what loopctl serves.
 * The sweep is the difference.
 *
 * SO IT PROVES "THE PACKAGE CALLS THIS ROUTE SOMEWHERE", not "THIS TOOL calls it". A route
 * called only from a function no dispatch case can reach would read as covered. That is closed
 * from the other end rather than by a call graph, for a MEASURED reason: a call-graph walk from
 * every dispatch case, built and run while writing this file (2026-09-15), found exactly ONE
 * apiCall-carrying function unreachable from a static case — `createGeneratedToolsRuntime` in
 * `lib/generated-tools.js`, which the ListTools handler calls to serve the dynamic per-tenant
 * `cr_*` tools, so it is reachable by a tool and is not a defect. Every other one was reachable
 * from a case. A hundred lines of parsing that can INVENT a gap, to find zero real ones, is the
 * wrong trade; the `declared <-> dispatched` assertion below covers the failure that actually
 * occurs — a tool declared with no `case`, or a `case` with no declaration.
 *
 * ## THE DECLARATION IS A RATCHET, NOT AN APPROVAL
 *
 * Nearly half of loopctl's `/api/v1` surface was unreached when this file was written
 * (2026-09-15) — the inventory below is the measurement, and it is the reason this is a ratchet
 * rather than a hard fail: failing on every one of them would make a test nobody can keep
 * green. They are declared below, and the ASSERTION is that the set does not grow silently.
 * Adding a route with no tool turns this red, and the remedy is a tool, or a line here saying
 * why not. The reverse is asserted too: a declaration whose route
 * has since become reached, or whose route no longer exists, is stale and must be deleted —
 * otherwise the list rots into an allowlist that hides the thing it was written to expose.
 *
 * Four categories are EXEMPT by kind — a tool for them would be unusable, not merely missing —
 * and the exemptions are declared here rather than assumed, as AC-3 requires:
 *
 *   - `machine`: the caller is a machine, never a session.
 *     `POST /api/v1/intake/github/:source_id` is GitHub's webhook delivery
 *     (`router.ex:169-173`, piped through `GithubIntakeThrottle`), and
 *     `GET /api/v1/tenants/:id/audit_public_key` is unauthenticated for an EXTERNAL verifier
 *     (`tenant_audit_key_controller.ex:6-7`: "intended for external verification").
 *   - `ceremony`: a challenge-bound WebAuthn reauthentication an MCP tool cannot complete.
 *     Rotation is two-step and verifies a client assertion against a stored, single-use
 *     challenge (`tenant_audit_key_controller.ex:7-16`); `bootstrap` is documented UNREACHABLE
 *     for every current and future tenant (`:29-31`). A tool could mint the challenge and
 *     could never answer it.
 *   - `superadmin`: the cross-tenant console under `scope "/api/v1/admin"`
 *     (`router.ex:740-741`), gated `exact_role: :superadmin` at the controller
 *     (`router.ex:771`). That is a different principal from every key this package sends, and
 *     two of the thirteen are additionally a WebAuthn break-glass ceremony
 *     (`router.ex:767-774`).
 *   - `duplicate`: the same action, already reached by a tool on its twin route. Phoenix's
 *     `resources` macro generates BOTH `PATCH` and `PUT` for `update` (`router.ex:340`, `:449`,
 *     `:499` and the other eight `resources` lines), and this package sends PATCH — so each
 *     `PUT` twin here is served, unused and harmless. `GET /api/v1` is the welcome landing;
 *     `list_routes` answers the same question by calling `GET /api/v1/routes` (`index.js`,
 *     `listRoutes`).
 *
 * Everything else is `gap` — a real, undone instance of the rule, recorded so the NEXT one is
 * caught the day it lands. A `gap` entry is a debt, not a decision: delete it when you ship
 * the tool.
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import path from "node:path";

import {
  PKG_DIR,
  apiCallSites,
  loadTools,
  normalisePath,
  reachedRoutes,
  routerRoutes,
} from "./tool-surface.js";

/**
 * Every `/api/v1` route no `apiCall` in this package sends, with why.
 *
 * KEYS ARE NORMALISED: `:id`, `:story_id` and friends all become `:param`, because that is
 * what `reachedRoutes()` can know from a template interpolation. Two router routes that differ
 * only in a parameter NAME therefore share one entry.
 */
const DECLARED = {
  // ── machine: the caller is a machine, never a session ──────────────────
  "GET /api/v1/tenants/:param/audit_public_key": "machine", // TenantAuditKeyController.show
  "POST /api/v1/intake/github/:param": "machine", // GithubIntakeController.deliver

  // ── ceremony: a WebAuthn challenge an MCP tool cannot answer ─────────────
  "POST /api/v1/tenants/:param/rotate-audit-key/challenge": "ceremony", // TenantAuditKeyController.challenge
  "POST /api/v1/tenants/:param/rotate-audit-key": "ceremony", // TenantAuditKeyController.rotate
  "POST /api/v1/tenants/:param/bootstrap-audit-key": "ceremony", // TenantAuditKeyController.bootstrap
  "GET /api/v1/tenants/:param/authenticators": "ceremony", // TenantAuthenticatorController.index
  "PATCH /api/v1/tenants/:param/authenticators/:param": "ceremony", // TenantAuthenticatorController.rename

  // ── superadmin: the cross-tenant console, a principal this package never holds
  "GET /api/v1/admin/tenants": "superadmin", // AdminTenantController.index
  "GET /api/v1/admin/tenants/:param": "superadmin", // AdminTenantController.show
  "PATCH /api/v1/admin/tenants/:param": "superadmin", // AdminTenantController.update
  "POST /api/v1/admin/tenants/:param/suspend": "superadmin", // AdminTenantController.suspend
  "POST /api/v1/admin/tenants/:param/activate": "superadmin", // AdminTenantController.activate
  "GET /api/v1/admin/stats": "superadmin", // AdminStatsController.show
  "GET /api/v1/admin/knowledge/retrieval-metrics": "superadmin", // AdminKnowledgeStatsController.index
  "GET /api/v1/admin/audit": "superadmin", // AdminAuditController.index
  "GET /api/v1/admin/violators": "superadmin", // AdminViolatorController.index
  "POST /api/v1/admin/violators/:param/resolve": "superadmin", // AdminViolatorController.resolve
  "POST /api/v1/admin/violators/:param/ignore": "superadmin", // AdminViolatorController.ignore
  "POST /api/v1/admin/tenants/:param/clear-halt/challenge": "superadmin", // AdminTenantController.clear_halt_challenge
  "POST /api/v1/admin/tenants/:param/clear-halt": "superadmin", // AdminTenantController.clear_halt

  // ── duplicate: the same action, reached by a tool on its twin route ───────
  "GET /api/v1": "duplicate", // WelcomeController.index
  "PUT /api/v1/intake/sources/:param": "duplicate", // IntakeSourceController.update
  "PUT /api/v1/projects/:param": "duplicate", // ProjectController.update
  "PUT /api/v1/webhooks/:param": "duplicate", // WebhookController.update
  "PUT /api/v1/skills/:param": "duplicate", // SkillController.update
  "PUT /api/v1/token-budgets/:param": "duplicate", // TokenBudgetController.update
  "PUT /api/v1/articles/:param": "duplicate", // ArticleController.update

  // ── gap: no tool reaches this. Real debt — delete the line when you ship one
  "GET /api/v1/audit/sth/:param/inclusion/:param": "gap", // AuditSthController.inclusion
  "GET /api/v1/channel/posts/quarantined": "gap", // ChannelPostController.quarantined
  "POST /api/v1/channel/posts/:param/release": "gap", // ChannelPostController.release
  "PATCH /api/v1/tenants/me": "gap", // TenantController.update
  "GET /api/v1/egress/trusted-endpoints": "gap", // EgressController.list_trusted
  "GET /api/v1/dispatches/:param": "gap", // DispatchController.show
  "GET /api/v1/dispatches": "gap", // DispatchController.index
  "POST /api/v1/api_keys": "gap", // ApiKeyController.create
  "GET /api/v1/api_keys": "gap", // ApiKeyController.index
  "DELETE /api/v1/api_keys/:param": "gap", // ApiKeyController.delete
  "POST /api/v1/api_keys/:param/rotate": "gap", // ApiKeyController.rotate
  "POST /api/v1/intake/sources": "gap", // IntakeSourceController.create
  "GET /api/v1/intake/sources": "gap", // IntakeSourceController.index
  "PATCH /api/v1/intake/sources/:param": "gap", // IntakeSourceController.update
  "DELETE /api/v1/intake/sources/:param": "gap", // IntakeSourceController.delete
  "GET /api/v1/audit": "gap", // AuditController.index
  "GET /api/v1/changes": "gap", // ChangeController.index
  "GET /api/v1/stories/blocked": "gap", // DependencyGraphController.blocked
  "POST /api/v1/stories/bulk/claim": "gap", // BulkOperationsController.claim
  "POST /api/v1/stories/bulk/verify": "gap", // BulkOperationsController.verify
  "POST /api/v1/stories/bulk/reject": "gap", // BulkOperationsController.reject
  "GET /api/v1/stories/:param/history": "gap", // StoryHistoryController.show
  "POST /api/v1/stories/:param/unclaim": "gap", // StoryStatusController.unclaim
  "POST /api/v1/stories/:param/report-done": "gap", // StoryStatusController.report
  "POST /api/v1/stories/:param/start-work": "gap", // StoryStatusController.start
  "POST /api/v1/stories/:param/artifacts": "gap", // ArtifactReportController.create
  "GET /api/v1/stories/:param/artifacts": "gap", // ArtifactReportController.index
  "GET /api/v1/stories/:param/verifications": "gap", // StoryVerificationController.index
  "POST /api/v1/stories/:param/merge-precondition": "gap", // MergePreconditionController.create
  "POST /api/v1/agents/register": "gap", // AgentController.register
  "GET /api/v1/agents": "gap", // AgentController.index
  "GET /api/v1/agents/:param": "gap", // AgentController.show
  "GET /api/v1/projects/:param": "gap", // ProjectController.show
  "PATCH /api/v1/projects/:param": "gap", // ProjectController.update
  "GET /api/v1/projects/:param/export": "gap", // ImportExportController.export_project
  "POST /api/v1/projects/:param/ui-tests": "gap", // UiTestController.create
  "GET /api/v1/projects/:param/ui-tests": "gap", // UiTestController.index
  "GET /api/v1/projects/:param/ui-tests/:param": "gap", // UiTestController.show
  "POST /api/v1/projects/:param/ui-tests/:param/findings": "gap", // UiTestController.add_finding
  "POST /api/v1/projects/:param/ui-tests/:param/complete": "gap", // UiTestController.complete
  "GET /api/v1/projects/:param/epics": "gap", // EpicController.index
  "POST /api/v1/projects/:param/epics": "gap", // EpicController.create
  "GET /api/v1/epics/:param": "gap", // EpicController.show
  "PATCH /api/v1/epics/:param": "gap", // EpicController.update
  "DELETE /api/v1/epics/:param": "gap", // EpicController.delete
  "GET /api/v1/epics/:param/progress": "gap", // EpicController.progress
  "GET /api/v1/epics/:param/stories": "gap", // StoryController.index
  "DELETE /api/v1/stories/:param": "gap", // StoryController.delete
  "GET /api/v1/projects/:param/dependency_graph": "gap", // DependencyGraphController.graph
  "POST /api/v1/epic_dependencies": "gap", // EpicDependencyController.create
  "DELETE /api/v1/epic_dependencies/:param": "gap", // EpicDependencyController.delete
  "GET /api/v1/projects/:param/epic_dependencies": "gap", // EpicDependencyController.index
  "POST /api/v1/story_dependencies": "gap", // StoryDependencyController.create
  "DELETE /api/v1/story_dependencies/:param": "gap", // StoryDependencyController.delete
  "GET /api/v1/epics/:param/story_dependencies": "gap", // StoryDependencyController.index
  "PUT /api/v1/orchestrator/state/:param": "gap", // OrchestratorStateController.save
  "GET /api/v1/orchestrator/state/:param": "gap", // OrchestratorStateController.show
  "GET /api/v1/orchestrator/state/:param/history": "gap", // OrchestratorStateController.history
  "POST /api/v1/webhooks": "gap", // WebhookController.create
  "GET /api/v1/webhooks": "gap", // WebhookController.index
  "PATCH /api/v1/webhooks/:param": "gap", // WebhookController.update
  "DELETE /api/v1/webhooks/:param": "gap", // WebhookController.delete
  "POST /api/v1/webhooks/:param/test": "gap", // WebhookController.test
  "GET /api/v1/webhooks/:param/deliveries": "gap", // WebhookController.deliveries
  "POST /api/v1/skills": "gap", // SkillController.create
  "GET /api/v1/skills": "gap", // SkillController.index
  "GET /api/v1/skills/:param": "gap", // SkillController.show
  "PATCH /api/v1/skills/:param": "gap", // SkillController.update
  "DELETE /api/v1/skills/:param": "gap", // SkillController.delete
  "POST /api/v1/skills/import": "gap", // SkillController.import_skills
  "POST /api/v1/skills/:param/versions": "gap", // SkillController.create_version
  "GET /api/v1/skills/:param/versions": "gap", // SkillController.list_versions
  "GET /api/v1/skills/:param/versions/:param": "gap", // SkillController.get_version
  "GET /api/v1/skills/:param/stats": "gap", // SkillController.stats
  "GET /api/v1/skills/:param/versions/:param/results": "gap", // SkillController.version_results
  "GET /api/v1/skills/:param/cost-performance": "gap", // SkillController.cost_performance
  "DELETE /api/v1/token-usage/:param": "gap", // TokenUsageController.delete
  "POST /api/v1/token-usage/:param/correction": "gap", // TokenUsageController.correct
  "GET /api/v1/token-budgets": "gap", // TokenBudgetController.index
  "GET /api/v1/token-budgets/:param": "gap", // TokenBudgetController.show
  "PATCH /api/v1/token-budgets/:param": "gap", // TokenBudgetController.update
  "DELETE /api/v1/token-budgets/:param": "gap", // TokenBudgetController.delete
  "PATCH /api/v1/cost-anomalies/:param": "gap", // CostAnomalyController.update
  "PATCH /api/v1/ingestion-anomalies/:param": "gap", // IngestionAnomalyController.update
  "GET /api/v1/analytics/trends": "gap", // AnalyticsController.trends
  "GET /api/v1/analytics/model-mix": "gap", // AnalyticsController.model_mix
  "GET /api/v1/analytics/agents/:param/model-profile": "gap", // AnalyticsController.agent_model_profile
  "POST /api/v1/skill_results": "gap", // SkillResultController.create
  "GET /api/v1/entities": "gap", // ContextRetrieverController.index
  "POST /api/v1/entities": "gap", // ContextRetrieverController.create
  "GET /api/v1/entities/:param": "gap", // ContextRetrieverController.show
  "PATCH /api/v1/entities/:param": "gap", // ContextRetrieverController.update
  "DELETE /api/v1/entities/:param": "gap", // ContextRetrieverController.delete
  "GET /api/v1/corpora/:param": "gap", // CorpusController.show
  "GET /api/v1/knowledge/export": "gap", // KnowledgeExportController.export
  "GET /api/v1/knowledge/pipeline": "gap", // KnowledgePipelineController.status
  "POST /api/v1/projects/:param/articles": "gap", // ArticleController.create
  "GET /api/v1/projects/:param/articles": "gap", // ArticleController.index
  "GET /api/v1/projects/:param/knowledge/export": "gap", // KnowledgeExportController.export
  "POST /api/v1/article_links": "gap", // ArticleLinkController.create
  "DELETE /api/v1/article_links/:param": "gap", // ArticleLinkController.delete
  "GET /api/v1/articles/:param/links": "gap", // ArticleLinkController.index
};

const EXEMPT_KINDS = new Set(["machine", "ceremony", "superadmin", "duplicate"]);

const REACHED = reachedRoutes();
const API_ROUTES = routerRoutes().filter((r) => r.path.startsWith("/api/v1"));

function routeKey(route) {
  return `${route.verb} ${normalisePath(route.path)}`;
}

const UNREACHED = API_ROUTES.filter((r) => !REACHED.has(routeKey(r)));

describe("the sweep reads what it claims to read", () => {
  test("the router parse finds loopctl's /api/v1 surface", () => {
    // A parse that silently found nothing would make every route "reached" by vacuity and
    // this whole file green for ever. Anchored on routes that must exist for the package to
    // work at all, not on a count (which is wrong by the next merge).
    const keys = new Set(API_ROUTES.map(routeKey));

    assert.ok(API_ROUTES.length > 100, `only ${API_ROUTES.length} /api/v1 routes were parsed`);
    assert.ok(keys.has("PATCH /api/v1/stories/:param"), "the story PATCH route was not parsed");
    assert.ok(keys.has("GET /api/v1/projects"), "the projects index was not parsed");
  });

  test("every apiCall site in the shipped files resolves to a path", () => {
    // `apiCallSites` returns `unresolved` rather than dropping a site it cannot read, because
    // a dropped site reads as an UNREACHED route — an invented gap, which teaches a reader to
    // ignore this list. A new call-expression shape fails here instead.
    const { resolved, unresolved } = apiCallSites();

    assert.deepEqual(
      unresolved,
      [],
      "an apiCall site could not be resolved to a path; teach resolveTemplate its shape " +
        "rather than letting it count as an unreached route",
    );
    assert.ok(resolved.length > 100, `only ${resolved.length} call sites resolved`);
  });

  test("the reached set contains routes this package demonstrably calls", () => {
    // Three call-expression shapes, so a resolver that broke on one of them is visible here
    // rather than as a phantom gap: a bare literal, a template with an interpolated id, and a
    // route built by a path builder in `lib/`.
    assert.ok(REACHED.has("GET /api/v1/routes"), "the literal-path shape stopped resolving");
    assert.ok(
      REACHED.has("PATCH /api/v1/stories/:param"),
      "the interpolated-id shape stopped resolving (update_story sends this one)",
    );
    assert.ok(
      REACHED.has("GET /.well-known/loopctl"),
      "the publicApiCall shape stopped resolving (mcp_version sends this one)",
    );
  });
});

describe("no /api/v1 route loses its tool silently", () => {
  test("every unreached route is declared, with a reason", () => {
    const undeclared = UNREACHED.map(routeKey)
      .filter((k) => !(k in DECLARED))
      .sort();

    assert.deepEqual(
      [...new Set(undeclared)],
      [],
      "this /api/v1 route is served by loopctl and called by no MCP tool. An operator-facing " +
        "endpoint is not done until a tool calls it (loopctl CLAUDE.md), and every session on " +
        "the fleet reaches loopctl through this package and only through it. Add the tool, or " +
        "add the route to DECLARED above with the category that says why a tool would be " +
        "unusable.",
    );
  });

  test("no declaration is stale — each one still names a route that exists", () => {
    // Without this, the list rots into an allowlist: a route deleted from the router, or a
    // typo'd key, sits here for ever and quietly excuses nothing.
    const live = new Set(API_ROUTES.map(routeKey));
    const dead = Object.keys(DECLARED)
      .filter((k) => !live.has(k))
      .sort();

    assert.deepEqual(dead, [], "DECLARED names a route loopctl no longer serves — delete it");
  });

  test("no declaration is stale — each one is still unreached", () => {
    // The half that makes the list a RATCHET. Ship the tool and this goes red until the line
    // is deleted, so the debt inventory can only shrink.
    const stillMissing = new Set(UNREACHED.map(routeKey));
    const covered = Object.keys(DECLARED)
      .filter((k) => !stillMissing.has(k))
      .sort();

    assert.deepEqual(
      covered,
      [],
      "a DECLARED route is now called by this package — delete its line; leaving it turns the " +
        "inventory into an allowlist",
    );
  });

  test("every declared category is one of the five this file defines", () => {
    const bad = Object.entries(DECLARED)
      .filter(([, kind]) => kind !== "gap" && !EXEMPT_KINDS.has(kind))
      .map(([route, kind]) => `${route}: ${kind}`);

    assert.deepEqual(bad, [], "an unknown category excuses a route without saying anything");
  });

  test("the declaration is not vacuous — it holds both exemptions and real debt", () => {
    // A future edit that collapsed every entry to one permissive category would leave the
    // assertions above green while saying nothing. Both kinds must be present, and the
    // exemptions must stay a small minority of the list.
    const kinds = Object.values(DECLARED);
    const gaps = kinds.filter((k) => k === "gap").length;
    const exempt = kinds.length - gaps;

    assert.ok(gaps > 0, "no route is declared a gap, which would mean loopctl has no debt here");
    assert.ok(exempt > 0, "no route is declared exempt, so the exemption kinds say nothing");
    assert.ok(
      exempt < gaps,
      "more routes are excused by kind than are admitted as debt — check that a gap has not " +
        "been relabelled into an exemption to quiet this file",
    );
  });
});

describe("every declared tool is actually dispatchable", () => {
  // The half a route sweep cannot see. `delivery_loop_tools.test.js` and the per-tool guards
  // pin this for the tools they name; this pins it for ALL of them, so a tool added with a
  // declaration and no `case` — invisible until someone calls it and gets "Unknown tool" —
  // cannot ship.
  const INDEX_SRC = readFileSync(path.join(PKG_DIR, "index.js"), "utf8");
  // Array.from, not .map: loadTools() evaluates the literal in a `vm` context, so its array
  // and everything derived from it belongs to ANOTHER REALM — and `deepStrictEqual` compares
  // prototypes, so a cross-realm empty array is not equal to `[]` and this assertion failed
  // with an empty diff while both sides were empty.
  const declared = Array.from(loadTools(), (t) => t.name);
  const dispatched = [...INDEX_SRC.matchAll(/^\s*case "([a-z0-9_]+)":/gm)].map((m) => m[1]);

  test("every tool in TOOLS has a dispatch case", () => {
    const orphaned = declared.filter((name) => !dispatched.includes(name)).sort();

    assert.deepEqual(
      orphaned,
      [],
      "this tool is declared on the surface and the CallTool switch does not handle it — a " +
        "session sees the name, calls it, and gets an unknown-tool error",
    );
  });

  test("every dispatch case has a declaration", () => {
    const hidden = dispatched.filter((name) => !declared.includes(name)).sort();

    assert.deepEqual(
      hidden,
      [],
      "this case handles a tool no session can see, because it is not in TOOLS",
    );
  });

  test("the wiring scan found both sides", () => {
    // Either regex silently matching nothing would make the two assertions above vacuous.
    assert.ok(declared.length > 50, `only ${declared.length} tools were read from TOOLS`);
    assert.ok(dispatched.length > 50, `only ${dispatched.length} dispatch cases were read`);
  });
});
