defmodule LoopctlWeb.Router do
  use LoopctlWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :protect_from_forgery

    plug :put_secure_browser_headers, %{
      "content-security-policy" =>
        "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; font-src 'self' https://fonts.gstatic.com; img-src 'self' data:; connect-src 'self' wss:"
    }
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug OpenApiSpex.Plug.PutApiSpec, module: Loopctl.ApiSpec
  end

  pipeline :authenticated do
    plug LoopctlWeb.Plugs.ExtractApiKey
    plug LoopctlWeb.Plugs.ResolveApiKey
    plug LoopctlWeb.Plugs.SetTenant
    plug LoopctlWeb.Plugs.SeedTenantMetadata
    plug LoopctlWeb.Plugs.RequireAuth
    plug LoopctlWeb.Plugs.Impersonate
    plug LoopctlWeb.Plugs.RateLimiter
    plug LoopctlWeb.Plugs.UpdateLastSeen
    plug LoopctlWeb.Plugs.ValidateWitnessHeader
    plug LoopctlWeb.Plugs.CheckCustodyHalt
  end

  # Landing page — browser pipeline (HTML)
  scope "/", LoopctlWeb do
    pipe_through :browser

    get "/", PageController, :home
    get "/docs", PageController, :docs
    get "/terms", PageController, :terms
    get "/privacy", PageController, :privacy

    # US-26.0.1 — tenant signup ceremony (LiveView with WebAuthn enrollment).
    # Lives in the public `:browser` pipeline and a dedicated
    # `:public_signup` live_session so it mounts without a current
    # scope. The session and onboarding routes deliberately sit
    # outside any authenticated pipeline — signup is the only way to
    # create a tenant and the resulting onboarding page is reachable
    # by URL until auth scoping is added in a follow-up story.
    # `session:` MFA resolves the client IP in the HTTP pipeline (where
    # `plug RemoteIp` has run and `fly-client-ip` is present) and signs it into
    # the session, so SignupLive gets an unspoofable per-IP rate-limit key on
    # both the disconnected and connected mount. See SignupLive.signup_session/1.
    live_session :public_signup,
      session: {LoopctlWeb.SignupLive, :signup_session, []} do
      live "/signup", SignupLive, :index
      live "/tenants/:id/onboarding", TenantOnboardingLive, :index
    end

    # US-26.0.3 — public wiki rendering for system-scoped articles
    live_session :public_wiki do
      live "/wiki", WikiIndexLive, :index
      live "/wiki/:slug", WikiShowLive, :show
    end
  end

  # Health check — unauthenticated JSON, outside /api/v1.
  # /health = LIVENESS (Fly's continuous http_service check, fly.toml).
  # /health/ready = READINESS (US-32.4 deploy-time smoke gate; NOT wired into fly.toml —
  # see Loopctl.HealthCheck.Default's moduledoc for why the two must stay decoupled).
  scope "/", LoopctlWeb do
    pipe_through :api

    get "/health", HealthController, :check
    get "/health/ready", HealthController, :ready
  end

  # US-26.0.4 — RFC 8615 discovery endpoint (unauthenticated)
  scope "/", LoopctlWeb do
    pipe_through :api

    get "/.well-known/loopctl", WellKnownController, :discovery
    get "/.well-known/loopctl/schema.json", WellKnownController, :schema
  end

  # OpenAPI spec, Swagger UI, and API discovery — available in all environments
  scope "/api/v1" do
    pipe_through [:api]

    get "/openapi", OpenApiSpex.Plug.RenderSpec, []
    get "/", LoopctlWeb.WelcomeController, :index
  end

  # US-26.0.2 — Public endpoint for tenant audit key (no auth required)
  # US-26.0.3 — Public system article endpoints (no auth required)
  # US-26.7.1 — Public agent-rooted self-signup (no auth required — there is
  # no key yet). Distinct from the HTML `/signup` LiveView above: different
  # pipeline (`:api` JSON, not `:browser`), different path, different method.
  scope "/api/v1", LoopctlWeb do
    pipe_through [:api]

    get "/tenants/:id/audit_public_key", TenantAuditKeyController, :show
    get "/articles/system", SystemArticleController, :index
    get "/audit/sth/:tenant_id", AuditSthController, :show
    post "/signup", SignupController, :create
  end

  scope "/swaggerui" do
    get "/", OpenApiSpex.Plug.SwaggerUI, path: "/api/v1/openapi"
  end

  # Convenience alias — agents and humans commonly try /swagger
  scope "/" do
    get "/swagger", LoopctlWeb.RedirectController, :swagger
  end

  # Dev-only routes (dashboard, etc.)
  if Application.compile_env(:loopctl, :dev_routes, false) do
  end

  # API v1 — all authenticated endpoints
  scope "/api/v1", LoopctlWeb do
    pipe_through [:api, :authenticated]

    get "/routes", RouteDiscoveryController, :index

    # Repo Coordination Bus (Epic 39) — the third memory plane. Agent-role write
    # to a project's transient coordination channel. NOT human-anchor gated
    # (coordination surface, owner decision #331). Per-key/per-tenant rate
    # limiting comes from the :authenticated pipeline RateLimiter; the controller
    # adds a tighter, config-driven per-write cap.
    post "/channel/posts", ChannelPostController, :create

    get "/tenants/me", TenantController, :show
    patch "/tenants/me", TenantController, :update

    # Per-tenant BYO Anthropic LLM config (Epic 28 residual, #179). Role :user —
    # the PATCH stores a tenant secret (enforced by the controller's RequireRole).
    # PATCH (partial-merge) mirrors the sibling PATCH /tenants/me.
    get "/tenants/me/llm-config", LlmConfigController, :show
    patch "/tenants/me/llm-config", LlmConfigController, :update
    post "/tenants/:id/rotate-audit-key/challenge", TenantAuditKeyController, :challenge
    post "/tenants/:id/rotate-audit-key", TenantAuditKeyController, :rotate
    post "/tenants/:id/bootstrap-audit-key", TenantAuditKeyController, :bootstrap

    # US-26.7.2 — opt-in WebAuthn trust-tier upgrade (agent_rooted -> human_anchored)
    # + authenticator revocation. Not tier-gated (enroll IS the upgrade path;
    # revoke + subsequent-enroll are protected by fresh WebAuthn assertions instead —
    # see require_human_anchor_default_deny_test.exs).
    post "/tenants/:id/authenticators/challenge", TenantAuthenticatorController, :challenge
    post "/tenants/:id/authenticators", TenantAuthenticatorController, :create

    post "/tenants/:id/authenticators/revoke-challenge",
         TenantAuthenticatorController,
         :revoke_challenge

    delete "/tenants/:id/authenticators/:auth_id", TenantAuthenticatorController, :delete

    # US-26.2.1 — Dispatch lineage
    resources "/dispatches", DispatchController, only: [:create, :show, :index]

    # API key management
    resources "/api_keys", ApiKeyController, only: [:create, :index, :delete]
    post "/api_keys/:id/rotate", ApiKeyController, :rotate

    # Audit log
    get "/audit", AuditController, :index

    # Change feed
    get "/changes", ChangeController, :index

    # Dependency graph queries (must be before stories/:id to avoid matching "ready"/"blocked")
    get "/stories/ready", DependencyGraphController, :ready
    get "/stories/blocked", DependencyGraphController, :blocked

    # Project-scoped story listing (must be before stories/:id to avoid route conflicts)
    get "/stories", StoryController, :index_by_project

    # Bulk operations (Epic 13) — must be before stories/:id to avoid route conflicts
    post "/stories/bulk/claim", BulkOperationsController, :claim
    post "/stories/bulk/verify", BulkOperationsController, :verify
    post "/stories/bulk/reject", BulkOperationsController, :reject
    post "/stories/bulk/mark-complete", BulkOperationsController, :mark_complete

    # Story history
    get "/stories/:id/history", StoryHistoryController, :show

    # US-26.4.1 — First-class acceptance criteria
    get "/stories/:story_id/acceptance_criteria", AcceptanceCriteriaController, :index

    # Cap recovery for session-crash resilience
    post "/stories/:id/recover-cap", CapRecoveryController, :recover

    # Story status transitions (agent side of two-tier trust model)
    post "/stories/:id/contract", StoryStatusController, :contract
    post "/stories/:id/claim", StoryStatusController, :claim
    post "/stories/:id/start", StoryStatusController, :start
    post "/stories/:id/request-review", StoryStatusController, :request_review
    post "/stories/:id/report", StoryStatusController, :report
    post "/stories/:id/unclaim", StoryStatusController, :unclaim
    # Discoverability aliases — same actions, alternate URL patterns agents tend to guess
    post "/stories/:id/report-done", StoryStatusController, :report
    post "/stories/:id/start-work", StoryStatusController, :start

    # Artifact reports (Epic 8)
    post "/stories/:id/artifacts", ArtifactReportController, :create
    get "/stories/:id/artifacts", ArtifactReportController, :index

    # Review pipeline completion (must precede verify)
    post "/stories/:id/review-complete", ReviewRecordController, :create

    # Story verification (orchestrator side of two-tier trust model)
    post "/stories/:id/verify", StoryVerificationController, :verify
    post "/stories/:id/reject", StoryVerificationController, :reject
    # Backfill: mark as verified for work completed outside loopctl.
    post "/stories/:id/backfill", StoryVerificationController, :backfill
    get "/stories/:story_id/verifications", StoryVerificationController, :index
    post "/stories/:id/force-unclaim", StoryVerificationController, :force_unclaim

    # Bulk epic verification (orchestrator convenience)
    post "/epics/:id/verify-all", StoryVerificationController, :verify_all

    # Agent management
    post "/agents/register", AgentController, :register
    get "/agents", AgentController, :index
    get "/agents/:id", AgentController, :show

    # Project management
    # Cheap repo -> project_id resolution (Gap 1 of #411). Must precede the
    # resources block so /projects/resolve is not captured by GET /projects/:id.
    get "/projects/resolve", ProjectController, :resolve
    # KB-only project scope: agent-createable (agent+ role, no human-anchor gate), forces
    # kind: :kb. Separate route so the human-anchored `POST /projects` stays untouched.
    post "/kb-scopes", ProjectController, :create_kb_scope
    # Archive (reversible soft-delete) an agent-owned :kb scope to reclaim its budget slot;
    # restore re-activates it (re-consumes a slot). Both agent-managed, no custody surface.
    delete "/kb-scopes/:id", ProjectController, :archive_kb_scope
    post "/kb-scopes/:id/restore", ProjectController, :restore_kb_scope
    resources "/projects", ProjectController, only: [:create, :index, :show, :update, :delete]
    get "/projects/:id/progress", ProjectController, :progress

    # Import/Export (Epic 12)
    post "/projects/:id/import", ImportExportController, :import_project
    get "/projects/:id/export", ImportExportController, :export_project

    # UI Test Runs
    post "/projects/:project_id/ui-tests", UiTestController, :create
    get "/projects/:project_id/ui-tests", UiTestController, :index
    get "/projects/:project_id/ui-tests/:id", UiTestController, :show
    post "/projects/:project_id/ui-tests/:id/findings", UiTestController, :add_finding
    post "/projects/:project_id/ui-tests/:id/complete", UiTestController, :complete

    # Epic management
    get "/projects/:project_id/epics", EpicController, :index
    post "/projects/:project_id/epics", EpicController, :create
    get "/epics/:id", EpicController, :show
    patch "/epics/:id", EpicController, :update
    delete "/epics/:id", EpicController, :delete
    get "/epics/:id/progress", EpicController, :progress

    # Story management
    get "/epics/:epic_id/stories", StoryController, :index
    post "/epics/:epic_id/stories", StoryController, :create
    # Agent-friendly alias: create a story by epic number instead of UUID.
    post "/projects/:project_id/stories", StoryController, :create_in_project
    get "/stories/:id", StoryController, :show
    patch "/stories/:id", StoryController, :update
    delete "/stories/:id", StoryController, :delete

    # Dependency graph
    get "/projects/:id/dependency_graph", DependencyGraphController, :graph

    # Epic dependencies
    post "/epic_dependencies", EpicDependencyController, :create
    delete "/epic_dependencies/:id", EpicDependencyController, :delete
    get "/projects/:id/epic_dependencies", EpicDependencyController, :index

    # Story dependencies
    post "/story_dependencies", StoryDependencyController, :create
    delete "/story_dependencies/:id", StoryDependencyController, :delete
    get "/epics/:id/story_dependencies", StoryDependencyController, :index

    # Orchestrator state
    put "/orchestrator/state/:project_id", OrchestratorStateController, :save
    get "/orchestrator/state/:project_id", OrchestratorStateController, :show
    get "/orchestrator/state/:project_id/history", OrchestratorStateController, :history

    # Webhooks (Epic 10)
    resources "/webhooks", WebhookController, only: [:create, :index, :update, :delete]
    post "/webhooks/:id/test", WebhookController, :test
    get "/webhooks/:id/deliveries", WebhookController, :deliveries

    # Skills (Epic 15)
    resources "/skills", SkillController, only: [:create, :index, :show, :update, :delete]
    # Literal paths must come before parameterized paths to avoid shadowing
    post "/skills/import", SkillController, :import_skills
    post "/skills/:id/versions", SkillController, :create_version
    get "/skills/:id/versions", SkillController, :list_versions
    get "/skills/:id/versions/:version", SkillController, :get_version
    get "/skills/:id/stats", SkillController, :stats
    get "/skills/:id/versions/:version/results", SkillController, :version_results
    # Skill cost performance (US-21.6)
    get "/skills/:id/cost-performance", SkillController, :cost_performance

    # Token usage (Epic 19, US-21.13)
    post "/token-usage", TokenUsageController, :create
    delete "/token-usage/:id", TokenUsageController, :delete
    post "/token-usage/:id/correction", TokenUsageController, :correct
    get "/stories/:story_id/token-usage", TokenUsageController, :index

    # Token budgets (Epic 19)
    resources "/token-budgets", TokenBudgetController,
      only: [:create, :index, :show, :update, :delete]

    # Cost anomalies (Epic 21)
    get "/cost-anomalies", CostAnomalyController, :index
    patch "/cost-anomalies/:id", CostAnomalyController, :update

    # Ingestion capture-silence anomalies (dead-man's-switch for knowledge capture)
    get "/ingestion-anomalies", IngestionAnomalyController, :index
    patch "/ingestion-anomalies/:id", IngestionAnomalyController, :update

    # Token analytics (Epic 21)
    get "/analytics/agents", AnalyticsController, :agents
    get "/analytics/epics", AnalyticsController, :epics
    get "/analytics/projects/:id", AnalyticsController, :project
    get "/analytics/models", AnalyticsController, :models
    get "/analytics/trends", AnalyticsController, :trends
    # Model-mix and agent model profile (US-21.5)
    get "/analytics/model-mix", AnalyticsController, :model_mix
    get "/analytics/agents/:id/model-profile", AnalyticsController, :agent_model_profile

    # Skill results
    post "/skill_results", SkillResultController, :create

    # Agent Memory (Epic 28, US-28.3) — thin JSON API over Loopctl.Memory.
    # Scope (tenant_id, subject_id) is derived from the key, never the body.
    # Literal /memory/recall must precede parameterized paths.
    post "/memory/recall", MemoryController, :recall
    # Literal /memory/promote must precede the parameterized delete so it is not
    # captured as an :id (US-29.3).
    post "/memory/promote", MemoryController, :promote
    # Literal /memory/graduate (#411 Gap 3 surface) — explicit per-memory graduation
    # into a durable knowledge article. Like /memory/promote it MUST precede the
    # parameterized delete below so it is not captured as an :id.
    post "/memory/graduate", MemoryController, :graduate
    post "/memory", MemoryController, :create
    get "/memory", MemoryController, :index
    delete "/memory/:id", MemoryController, :delete

    # Merged recall (Epic 28 / #411 Gap 2) — ONE round-trip returning the re-ranked
    # `global ∪ active-project` union of long-term memory AND knowledge. Reuses the
    # MemoryController scope-from-key + project-partition helpers.
    post "/recall", MemoryController, :context

    # Context Retriever (Epic 30, US-30.4) — entity-definition CRUD + the
    # model-invoked query surface. Literal /retrieve/tools MUST precede the
    # parameterized /retrieve/:entity so it is not captured as an :entity.
    get "/entities", ContextRetrieverController, :index
    post "/entities", ContextRetrieverController, :create
    get "/entities/:id", ContextRetrieverController, :show
    patch "/entities/:id", ContextRetrieverController, :update
    delete "/entities/:id", ContextRetrieverController, :delete
    get "/retrieve/tools", ContextRetrieverController, :tools
    post "/retrieve/:entity", ContextRetrieverController, :retrieve

    # Knowledge Wiki (Epic 19)
    # Publish workflow routes (must precede resources to avoid route conflicts)
    post "/articles/:id/publish", ArticleWorkflowController, :publish
    post "/articles/:id/unpublish", ArticleWorkflowController, :unpublish
    post "/articles/:id/archive", ArticleWorkflowController, :archive
    resources "/articles", ArticleController, except: [:new, :edit]

    # Knowledge bulk-publish, bulk-delete, and drafts queue
    post "/knowledge/bulk-publish", ArticleWorkflowController, :bulk_publish
    post "/knowledge/bulk-unpublish", ArticleWorkflowController, :bulk_unpublish
    post "/knowledge/bulk-delete", ArticleWorkflowController, :bulk_delete
    get "/knowledge/drafts", ArticleWorkflowController, :drafts
    get "/knowledge/conflicts", ArticleWorkflowController, :conflicts
    post "/knowledge/conflicts/resolve", ArticleWorkflowController, :resolve_conflict

    # Knowledge Index (lightweight catalog)
    get "/knowledge/index", KnowledgeIndexController, :index

    # Knowledge Stats (aggregate counts by category/status)
    get "/knowledge/stats", KnowledgeStatsController, :stats

    # Knowledge Count + Facets (filtered counts and count-by-tag, no rows)
    get "/knowledge/count", KnowledgeFacetsController, :count
    get "/knowledge/facets", KnowledgeFacetsController, :facets

    # Knowledge Graph (multi-hop traversal of the article-link graph)
    get "/knowledge/graph", KnowledgeGraphController, :graph

    # Creativity primitives (distant pairs, novelty scoring, random walk)
    get "/knowledge/pairs", KnowledgeCreativityController, :pairs
    post "/knowledge/novelty", KnowledgeCreativityController, :novelty
    get "/knowledge/walk", KnowledgeCreativityController, :walk

    # Knowledge Search (unified keyword / semantic / combined)
    get "/knowledge/search", KnowledgeSearchController, :search

    # Hybrid retrieval (curated-first, retrieval fallback, with provenance) — US-31.4.
    # POST (vs the GET search endpoint) carries the richer JSON body.
    post "/knowledge/hybrid_search", KnowledgeHybridSearchController, :hybrid_search

    # Progressive disclosure (US-31.3/31.4): compact topic index, then drill into one
    # article's body. The literal `progressive_index` path is registered BEFORE the
    # parameterized `progressive/:id` drill so it can never be shadowed.
    get "/knowledge/progressive_index", KnowledgeProgressiveController, :index
    get "/knowledge/progressive/:id", KnowledgeProgressiveController, :drill

    # Knowledge Context (deep-read with recency scoring and linked refs)
    get "/knowledge/context", KnowledgeContextController, :context

    # Knowledge Export (Obsidian-compatible ZIP)
    get "/knowledge/export", KnowledgeExportController, :export

    # OKF (Open Knowledge Format) interchange — export bundle / import bundle
    get "/knowledge/okf/export", OKFController, :export
    post "/knowledge/okf/import", OKFController, :import

    # Knowledge Lint (quality analysis report)
    get "/knowledge/lint", KnowledgeLintController, :lint

    # Knowledge Pipeline (self-learning pipeline status)
    get "/knowledge/pipeline", KnowledgePipelineController, :status

    # Knowledge Ingestion (content extraction pipeline)
    post "/knowledge/ingest", KnowledgeIngestionController, :create
    post "/knowledge/ingest/batch", KnowledgeIngestionController, :create_batch
    get "/knowledge/ingestion-jobs", KnowledgeIngestionController, :index

    # Per-tenant LLM token-usage summary (Epic 28 residual, #179). Role: orchestrator+.
    get "/knowledge/llm-usage", LlmUsageController, :index

    # Knowledge Analytics (article usage tracking — orchestrator+)
    get "/knowledge/analytics/top-articles",
        KnowledgeAnalyticsController,
        :top_articles

    get "/knowledge/analytics/unused-articles",
        KnowledgeAnalyticsController,
        :unused_articles

    get "/knowledge/analytics/retrieval-metrics",
        KnowledgeAnalyticsController,
        :retrieval_metrics

    get "/knowledge/curation-log", KnowledgeAnalyticsController, :curation_log

    get "/knowledge/analytics/agents/:agent_id",
        KnowledgeAnalyticsController,
        :agent_usage

    get "/knowledge/analytics/projects/:id/usage",
        KnowledgeAnalyticsController,
        :project_usage

    get "/knowledge/articles/:id/stats",
        KnowledgeAnalyticsController,
        :article_stats

    scope "/projects/:project_id" do
      resources "/articles", ArticleController, only: [:create, :index], as: :project_article
      get "/knowledge/index", KnowledgeIndexController, :index
      get "/knowledge/stats", KnowledgeStatsController, :stats
      get "/knowledge/export", KnowledgeExportController, :export
      get "/knowledge/okf/export", OKFController, :export
      get "/knowledge/lint", KnowledgeLintController, :lint
    end

    # ArticleLink management
    resources "/article_links", ArticleLinkController, only: [:create, :delete]
    get "/articles/:article_id/links", ArticleLinkController, :index

    # Suggested typed-link candidates (read-only; embedding similarity)
    get "/knowledge/articles/:id/suggested_links",
        KnowledgeSuggestLinksController,
        :suggest
  end

  # Superadmin endpoints (Epic 11)
  scope "/api/v1/admin", LoopctlWeb do
    pipe_through [:api, :authenticated]

    # Tenant management
    get "/tenants", AdminTenantController, :index
    get "/tenants/:id", AdminTenantController, :show
    patch "/tenants/:id", AdminTenantController, :update
    post "/tenants/:id/suspend", AdminTenantController, :suspend
    post "/tenants/:id/activate", AdminTenantController, :activate

    # System-wide stats
    get "/stats", AdminStatsController, :show

    # Cross-tenant audit log
    get "/audit", AdminAuditController, :index

    # US-26.1.4 — Pre-existing violation management
    get "/violators", AdminViolatorController, :index
    post "/violators/:id/resolve", AdminViolatorController, :resolve
    post "/violators/:id/ignore", AdminViolatorController, :ignore

    # US-26.5.2 — Custody halt management
    post "/tenants/:id/clear-halt", AdminTenantController, :clear_halt
  end
end
