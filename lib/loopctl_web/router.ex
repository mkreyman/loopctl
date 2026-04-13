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
    plug LoopctlWeb.Plugs.RequireAuth
    plug LoopctlWeb.Plugs.Impersonate
    plug LoopctlWeb.Plugs.RateLimiter
    plug LoopctlWeb.Plugs.UpdateLastSeen
    plug LoopctlWeb.Plugs.ValidateWitnessHeader
  end

  pipeline :registration_rate_limit do
    plug LoopctlWeb.Plugs.RegistrationRateLimiter
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
    live_session :public_signup do
      live "/signup", SignupLive, :index
      live "/tenants/:id/onboarding", TenantOnboardingLive, :index
    end

    # US-26.0.3 — public wiki rendering for system-scoped articles
    live_session :public_wiki do
      live "/wiki", WikiIndexLive, :index
      live "/wiki/:slug", WikiShowLive, :show
    end
  end

  # Health check — unauthenticated JSON, outside /api/v1
  scope "/", LoopctlWeb do
    pipe_through :api

    get "/health", HealthController, :check
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
  scope "/api/v1", LoopctlWeb do
    pipe_through [:api]

    get "/tenants/:id/audit_public_key", TenantAuditKeyController, :show
    get "/articles/system", SystemArticleController, :index
    get "/audit/sth/:tenant_id", AuditSthController, :show
  end

  scope "/swaggerui" do
    get "/", OpenApiSpex.Plug.SwaggerUI, path: "/api/v1/openapi"
  end

  # Dev-only routes (dashboard, etc.)
  if Application.compile_env(:loopctl, :dev_routes, false) do
  end

  # API v1 — all authenticated endpoints
  scope "/api/v1", LoopctlWeb do
    pipe_through [:api, :authenticated]

    get "/routes", RouteDiscoveryController, :index

    get "/tenants/me", TenantController, :show
    patch "/tenants/me", TenantController, :update
    post "/tenants/:id/rotate-audit-key", TenantAuditKeyController, :rotate

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
    get "/stories/:story_id/verifications", StoryVerificationController, :index
    post "/stories/:id/force-unclaim", StoryVerificationController, :force_unclaim

    # Bulk epic verification (orchestrator convenience)
    post "/epics/:id/verify-all", StoryVerificationController, :verify_all

    # Agent management
    post "/agents/register", AgentController, :register
    get "/agents", AgentController, :index
    get "/agents/:id", AgentController, :show

    # Project management
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

    # Knowledge Wiki (Epic 19)
    # Publish workflow routes (must precede resources to avoid route conflicts)
    post "/articles/:id/publish", ArticleWorkflowController, :publish
    post "/articles/:id/unpublish", ArticleWorkflowController, :unpublish
    post "/articles/:id/archive", ArticleWorkflowController, :archive
    resources "/articles", ArticleController, except: [:new, :edit]

    # Knowledge bulk-publish and drafts queue
    post "/knowledge/bulk-publish", ArticleWorkflowController, :bulk_publish
    get "/knowledge/drafts", ArticleWorkflowController, :drafts

    # Knowledge Index (lightweight catalog)
    get "/knowledge/index", KnowledgeIndexController, :index

    # Knowledge Search (unified keyword / semantic / combined)
    get "/knowledge/search", KnowledgeSearchController, :search

    # Knowledge Context (deep-read with recency scoring and linked refs)
    get "/knowledge/context", KnowledgeContextController, :context

    # Knowledge Export (Obsidian-compatible ZIP)
    get "/knowledge/export", KnowledgeExportController, :export

    # Knowledge Lint (quality analysis report)
    get "/knowledge/lint", KnowledgeLintController, :lint

    # Knowledge Pipeline (self-learning pipeline status)
    get "/knowledge/pipeline", KnowledgePipelineController, :status

    # Knowledge Ingestion (content extraction pipeline)
    post "/knowledge/ingest", KnowledgeIngestionController, :create
    post "/knowledge/ingest/batch", KnowledgeIngestionController, :create_batch
    get "/knowledge/ingestion-jobs", KnowledgeIngestionController, :index

    # Knowledge Analytics (article usage tracking — orchestrator+)
    get "/knowledge/analytics/top-articles",
        KnowledgeAnalyticsController,
        :top_articles

    get "/knowledge/analytics/unused-articles",
        KnowledgeAnalyticsController,
        :unused_articles

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
      get "/knowledge/export", KnowledgeExportController, :export
      get "/knowledge/lint", KnowledgeLintController, :lint
    end

    # ArticleLink management
    resources "/article_links", ArticleLinkController, only: [:create, :delete]
    get "/articles/:article_id/links", ArticleLinkController, :index
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
  end
end
