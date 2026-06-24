Mox.defmock(Loopctl.MockHealthChecker, for: Loopctl.HealthCheck.Behaviour)
Mox.defmock(Loopctl.MockRateLimiter, for: Loopctl.RateLimiter.Behaviour)
Mox.defmock(Loopctl.MockClock, for: Loopctl.Clock.Behaviour)
Mox.defmock(Loopctl.MockCostRollup, for: Loopctl.TokenUsage.RollupBehaviour)
Mox.defmock(Loopctl.MockTokenArchival, for: Loopctl.TokenUsage.ArchivalBehaviour)
Mox.defmock(Loopctl.MockEmbeddingClient, for: Loopctl.Knowledge.EmbeddingBehaviour)
Mox.defmock(Loopctl.MockExtractor, for: Loopctl.Knowledge.ExtractorBehaviour)
Mox.defmock(Loopctl.MockContentExtractor, for: Loopctl.Knowledge.ContentExtractorBehaviour)
Mox.defmock(Loopctl.MockWebAuthn, for: Loopctl.WebAuthn.Behaviour)
Mox.defmock(Loopctl.MockSecrets, for: Loopctl.Secrets.Behaviour)
Mox.defmock(Loopctl.MockSuggestLinks, for: Loopctl.Knowledge.SuggestLinksBehaviour)

# US-27.3: a Plug-shaped mock standing in for LoopctlWeb.Router so the
# DBErrorBackstop's catch/log/sanitize path can be exercised by injecting a
# router that raises a DB exception uncaught — without mounting a test-only route
# on the production router. The default stub (DataCase.stub_all_defaults/0)
# delegates to the real router so every other request flows normally.
Mox.defmock(Loopctl.MockBackstopRouter, for: Plug)
