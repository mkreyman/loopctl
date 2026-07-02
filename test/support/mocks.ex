Mox.defmock(Loopctl.MockHealthChecker, for: Loopctl.HealthCheck.Behaviour)
Mox.defmock(Loopctl.MockRateLimiter, for: Loopctl.RateLimiter.Behaviour)
Mox.defmock(Loopctl.MockClock, for: Loopctl.Clock.Behaviour)
Mox.defmock(Loopctl.MockCostRollup, for: Loopctl.TokenUsage.RollupBehaviour)
Mox.defmock(Loopctl.MockTokenArchival, for: Loopctl.TokenUsage.ArchivalBehaviour)
Mox.defmock(Loopctl.MockEmbeddingClient, for: Loopctl.Knowledge.EmbeddingBehaviour)
Mox.defmock(Loopctl.MockExtractor, for: Loopctl.Knowledge.ExtractorBehaviour)
Mox.defmock(Loopctl.MockContentExtractor, for: Loopctl.Knowledge.ContentExtractorBehaviour)
Mox.defmock(Loopctl.MockCategoryClassifier, for: Loopctl.Knowledge.ClassifierBehaviour)
Mox.defmock(Loopctl.MockWebAuthn, for: Loopctl.WebAuthn.Behaviour)
Mox.defmock(Loopctl.MockSecrets, for: Loopctl.Secrets.Behaviour)
Mox.defmock(Loopctl.MockSuggestLinks, for: Loopctl.Knowledge.SuggestLinksBehaviour)
Mox.defmock(Loopctl.MockProposalAssessor, for: Loopctl.Knowledge.ProposalAssessorBehaviour)
Mox.defmock(Loopctl.MockMergeSynthesizer, for: Loopctl.Knowledge.MergeSynthesizerBehaviour)
# ArticleLinkingWorker's injectable similarity lookup. Lets the worker's linking-logic
# unit tests feed deterministic candidate lists instead of exercising the real 250ms-timed
# pgvector heavy read (the flake source). DataCase default-stubs `nearest/4` to return [].
Mox.defmock(Loopctl.MockArticleSimilaritySearch,
  for: Loopctl.Knowledge.SimilaritySearch.Behaviour
)

# US-27.15: webhook delivery DI. ScaleAlerts and the webhook worker share the
# `:webhook_delivery` key. In :test it resolves to this mock; the DataCase default stub
# delegates to Loopctl.Webhooks.ReqDelivery so the existing Req.Test-stub-based webhook
# worker tests keep working, while the ScaleAlerts tests override deliver/3 directly.
Mox.defmock(Loopctl.MockDelivery, for: Loopctl.Webhooks.DeliveryBehaviour)

# US-27.3: the DBErrorBackstop test seam is a REAL plug (Loopctl.Test.BackstopRouter,
# wired via config/test.exs), NOT a Mox mock — so the production router stays on
# the hot path for every request and the catch/log/sanitize path is exercised by
# an opt-in `x-test-raise-db-error` request header rather than a global mock.
