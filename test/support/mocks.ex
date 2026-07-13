Mox.defmock(Loopctl.MockHealthChecker, for: Loopctl.HealthCheck.Behaviour)
Mox.defmock(Loopctl.MockRateLimiter, for: Loopctl.RateLimiter.Behaviour)
Mox.defmock(Loopctl.MockClock, for: Loopctl.Clock.Behaviour)
Mox.defmock(Loopctl.MockCostRollup, for: Loopctl.TokenUsage.RollupBehaviour)
Mox.defmock(Loopctl.MockTokenArchival, for: Loopctl.TokenUsage.ArchivalBehaviour)
Mox.defmock(Loopctl.MockEmbeddingClient, for: Loopctl.Knowledge.EmbeddingBehaviour)
Mox.defmock(Loopctl.MockExtractor, for: Loopctl.Knowledge.ExtractorBehaviour)
Mox.defmock(Loopctl.MockContentExtractor, for: Loopctl.Knowledge.ContentExtractorBehaviour)
Mox.defmock(Loopctl.MockPromoterLLM, for: Loopctl.Memory.Promoter.LLMBehaviour)
Mox.defmock(Loopctl.MockCategoryClassifier, for: Loopctl.Knowledge.ClassifierBehaviour)
Mox.defmock(Loopctl.MockWebAuthn, for: Loopctl.WebAuthn.Behaviour)
Mox.defmock(Loopctl.MockSecrets, for: Loopctl.Secrets.Behaviour)
Mox.defmock(Loopctl.MockSuggestLinks, for: Loopctl.Knowledge.SuggestLinksBehaviour)
Mox.defmock(Loopctl.MockProposalAssessor, for: Loopctl.Knowledge.ProposalAssessorBehaviour)
Mox.defmock(Loopctl.MockMergeSynthesizer, for: Loopctl.Knowledge.MergeSynthesizerBehaviour)

# US-30.3: Context-Retriever audit writer DI. The executor treats the audit write
# as part of the read's correctness (AC-30.3.6 fail-closed). The DataCase default
# stub delegates to the real Loopctl.Audit so existing executor tests still write
# and read back real audit rows; the fail-closed test overrides create_log_entry/2
# with Mox.expect/3 to return {:error, _}.
Mox.defmock(Loopctl.ContextRetriever.MockAudit,
  for: Loopctl.ContextRetriever.AuditBehaviour
)

# ArticleLinkingWorker's injectable similarity lookup. Lets the worker's linking-logic
# unit tests feed deterministic candidate lists instead of exercising the real 250ms-timed
# pgvector heavy read (the flake source). DataCase default-stubs `nearest/4` to return [].
Mox.defmock(Loopctl.MockArticleSimilaritySearch,
  for: Loopctl.Knowledge.SimilaritySearchBehaviour
)

# US-27.15: webhook delivery DI. ScaleAlerts and the webhook worker share the
# `:webhook_delivery` key. In :test it resolves to this mock; the DataCase default stub
# delegates to Loopctl.Webhooks.ReqDelivery so the existing Req.Test-stub-based webhook
# worker tests keep working, while the ScaleAlerts tests override deliver/3 directly.
Mox.defmock(Loopctl.MockDelivery, for: Loopctl.Webhooks.DeliveryBehaviour)

# SSRF egress guard (ie-02 / worker-01) DNS resolution DI. Lets UrlGuard tests
# feed deterministic A/AAAA records for a bare hostname without touching real DNS.
# DataCase default-stubs `resolve/1` to a public IP so hostname-based webhook and
# ingestion tests pass; DNS-rebinding tests override it to return a private address.
Mox.defmock(Loopctl.MockDnsResolver, for: Loopctl.Net.DnsResolver.Behaviour)

# US-32.4: scale-alerts config-guard DI. Lets `Loopctl.HealthCheck.Default`'s degraded
# branch (checks.scale_alerts == "error", reasons attached, ready == false) be exercised
# via Mox.expect/3 without `Application.put_env`. The DataCase default stub delegates to
# the real `Loopctl.Telemetry.ScaleAlerts.config_status/0` so every existing health-check
# test (config: scale_alerts_enabled false) keeps passing unchanged.
Mox.defmock(Loopctl.MockScaleAlertsConfigChecker,
  for: Loopctl.Telemetry.ScaleAlerts.ConfigStatusBehaviour
)

# US-34.2: Oban orphan-count DI. Lets `Loopctl.HealthCheck.Default`'s degraded
# branch (checks.oban_orphans == "error", reasons attached, ready == false) be
# exercised via Mox.expect/3 without inserting real `oban_jobs` rows. Production
# (no Mox override) resolves to the real `Loopctl.Telemetry.ScaleMetrics`, whose
# `cached_executing_orphan_count/0` reads the `:persistent_term` value US-34.1's
# poller last cached (review finding — avoids a fresh DB query per health-check
# call). The DataCase default stub instead delegates to the real, freshly-queried
# `count_oban_executing_orphans/0` so every existing health-check test (no
# orphans present, or real rows inserted within the test's own sandboxed
# transaction) keeps passing unchanged and isolated.
Mox.defmock(Loopctl.MockObanOrphanCountChecker,
  for: Loopctl.Telemetry.ScaleMetrics.OrphanCountBehaviour
)

# US-27.3: the DBErrorBackstop test seam is a REAL plug (Loopctl.Test.BackstopRouter,
# wired via config/test.exs), NOT a Mox mock — so the production router stays on
# the hot path for every request and the catch/log/sanitize path is exercised by
# an opt-in `x-test-raise-db-error` request header rather than a global mock.
