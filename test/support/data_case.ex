defmodule Loopctl.DataCase do
  @moduledoc """
  This module defines the setup for tests requiring
  access to the application's data layer.

  You may define functions here to be used as helpers in
  your tests.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use Loopctl.DataCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL.Sandbox
  alias Loopctl.Custody.Coverage
  alias Loopctl.Egress.Scope, as: EgressScope
  alias Loopctl.Oban.FairShare
  alias Loopctl.Telemetry.ScaleAlerts
  alias Loopctl.Telemetry.ScaleMetrics
  alias Loopctl.Webhooks.ReqDelivery

  using do
    quote do
      alias Loopctl.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import Loopctl.DataCase
      import Loopctl.Fixtures
      import Mox
    end
  end

  setup tags do
    Loopctl.DataCase.setup_sandbox(tags)
    Mox.set_mox_from_context(tags)
    stub_all_defaults()
    :ok
  end

  @doc """
  Sets up the sandbox based on the test tags.
  Configures Repo, AdminRepo, and HeavyReadRepo (US-27.11) for test isolation.
  """
  def setup_sandbox(tags) do
    pid = Sandbox.start_owner!(Loopctl.Repo, shared: not tags[:async])
    admin_pid = Sandbox.start_owner!(Loopctl.AdminRepo, shared: not tags[:async])
    heavy_pid = Sandbox.start_owner!(Loopctl.HeavyReadRepo, shared: not tags[:async])

    on_exit(fn ->
      Sandbox.stop_owner(pid)
      Sandbox.stop_owner(admin_pid)
      Sandbox.stop_owner(heavy_pid)
    end)
  end

  @doc """
  Sets permissive default stubs for all Mox mocks.

  These stubs allow tests to run without explicitly setting up
  expectations for every mock. Override with `expect/3` in individual
  tests as needed.
  """
  def stub_all_defaults do
    # US-41.7: production coverage by default, so every pre-existing test sees the
    # real `Loopctl.Custody.Coverage` behaviour; TC-41.7.8 overrides it.
    Mox.stub(Loopctl.MockCustodyCoverage, :covered_paths, fn ->
      Coverage.covered_paths()
    end)

    Mox.stub(Loopctl.MockHealthChecker, :check, fn ->
      {:ok,
       %{
         status: "ok",
         ready: true,
         version: "0.1.0-test",
         checks: %{database: "ok", oban: "ok"}
       }}
    end)

    # US-32.4: default delegates to the real config_status/0 so the healthy path
    # (scale_alerts_enabled: false in config/test.exs) is exercised unchanged. The
    # degraded-branch test overrides this with Mox.expect/3.
    Mox.stub(Loopctl.MockScaleAlertsConfigChecker, :config_status, fn ->
      ScaleAlerts.config_status()
    end)

    # US-34.2: default delegates to the real count_oban_executing_orphans/0 — a
    # FRESH, per-call query scoped to THIS test's own sandboxed transaction — so
    # the healthy path (no orphans present) and end-to-end tests inserting real
    # `oban_jobs` rows are both exercised unchanged. Deliberately NOT
    # `ScaleMetrics.cached_executing_orphan_count/0` (what production resolves to
    # via the real `ScaleMetrics` module): that reads a single VM-wide
    # `:persistent_term` slot, which is NOT sandboxed per test — stubbing the
    # default to it would leak orphan counts across concurrently running async
    # tests. The degraded-branch test overrides this with Mox.expect/3.
    Mox.stub(Loopctl.MockObanOrphanCountChecker, :cached_executing_orphan_count, fn ->
      {:ok, ScaleMetrics.count_oban_executing_orphans()}
    end)

    # US-36.3: default delegates to the real FairShare.in_flight_ingestion_backlog/1 — a
    # fresh, per-call count scoped to THIS test's own sandboxed transaction — so every
    # existing batch-ingest backlog test (seeded oban_jobs rows) exercises the real
    # count unchanged. The fail-open test overrides this with Mox.expect/3 to raise,
    # deterministically driving the controller's fail-open (count error -> admit) path.
    Mox.stub(Loopctl.MockBacklogCounter, :in_flight_ingestion_backlog, fn tenant_id ->
      FairShare.in_flight_ingestion_backlog(tenant_id)
    end)

    Mox.stub(Loopctl.MockRateLimiter, :check_rate, fn _bucket, _window, _limit ->
      {:allow, 1}
    end)

    Mox.stub(Loopctl.MockClock, :utc_now, fn ->
      DateTime.utc_now()
    end)

    # Default stub for cost rollup -- returns empty results
    Mox.stub(Loopctl.MockCostRollup, :aggregate, fn _tenant_id, _start, _end ->
      {:ok, []}
    end)

    # Default stub for token archival -- returns zero counts
    Mox.stub(Loopctl.MockTokenArchival, :soft_delete_old_reports, fn _tenant_id, _days ->
      {:ok, 0}
    end)

    Mox.stub(Loopctl.MockTokenArchival, :hard_delete_expired_reports, fn _tenant_id ->
      {:ok, 0}
    end)

    Mox.stub(Loopctl.MockTokenArchival, :archive_old_anomalies, fn _tenant_id, _days ->
      {:ok, 0}
    end)

    # Default stub for embedding client -- a DETERMINISTIC FUNCTION OF THE INPUT
    # TENANT (see `deterministic_embedding/1`), never a global constant. The old
    # constant `List.duplicate(0.1, 1536)` made EVERY memory in EVERY tenant
    # identical, so the single, globally-shared pgvector HNSW index on `memories`
    # became one giant all-ties clique. Under concurrent full-suite load the graph
    # walk cannot navigate that clique and non-deterministically MISSED exact
    # matches, so near-dup supersede duplicated and scoped recalls came back empty
    # (issue #421). Keying the vector on `tenant_id` gives each tenant its OWN
    # well-separated point: within a tenant every text still maps to the SAME
    # vector (so cross-text recall — query "drain" finding "batch drainer" — keeps
    # working exactly as before, no test rewrites), but tenants no longer crowd
    # each other's region of the index, so recall is deterministic under load.
    # tenant_id is threaded first (BYO embeddings, #294 extended).
    Mox.stub(Loopctl.MockEmbeddingClient, :generate_embedding, fn scope, _text ->
      {:ok, deterministic_embedding(EgressScope.coerce(scope).tenant_id)}
    end)

    # US-37.4: permissive default for the BATCH embedding path -- one 1536-dim vector
    # per input text, preserving input order (the real client maps by response index;
    # this deterministic stub returns them aligned so batch worker/store tests run
    # unchanged). Keyed on `tenant_id` (never a global constant) for the same
    # index-navigability reason as the single path above. An empty batch returns [].
    Mox.stub(Loopctl.MockEmbeddingClient, :generate_embeddings, fn scope, texts ->
      tenant_id = EgressScope.coerce(scope).tenant_id
      {:ok, Enum.map(texts, fn _text -> deterministic_embedding(tenant_id) end)}
    end)

    # US-41.1 AC-41.1.10: the `/3` arities carry an explicit `:model` override (the
    # model that produced the tenant's ACTIVE corpus, or — for the re-embed worker —
    # the pending one). The default stubs ignore the model and behave EXACTLY like
    # their `/2` twins, so only a test that actually asserts on the model needs its
    # own expectation.
    Mox.stub(Loopctl.MockEmbeddingClient, :generate_embedding, fn scope, _text, _opts ->
      {:ok, deterministic_embedding(EgressScope.coerce(scope).tenant_id)}
    end)

    Mox.stub(Loopctl.MockEmbeddingClient, :generate_embeddings, fn scope, texts, _opts ->
      tenant_id = EgressScope.coerce(scope).tenant_id
      {:ok, Enum.map(texts, fn _text -> deterministic_embedding(tenant_id) end)}
    end)

    # US-37.2: permissive default for the per-node embedding concurrency gate --
    # acquire/1 always grants a slot, release/1 is a no-op -- so every existing
    # embedding/search test runs under the cap unchanged. The saturation test
    # overrides acquire/1 to return {:error, :rate_limited_local}.
    Mox.stub(Loopctl.MockEmbeddingConcurrency, :acquire, fn _tenant_id -> :ok end)
    Mox.stub(Loopctl.MockEmbeddingConcurrency, :release, fn _tenant_id -> :ok end)

    # Default stub for knowledge extractor -- returns empty list (no articles).
    # tenant_id is threaded first (Epic 28 BYO, review #1).
    Mox.stub(Loopctl.MockExtractor, :extract_articles, fn _tenant_id, _ctx ->
      {:ok, []}
    end)

    # Default stub for content extractor -- returns empty list (no articles).
    # tenant_id is threaded first (Epic 28 BYO); tests that assert threading match on it.
    Mox.stub(Loopctl.MockContentExtractor, :extract_from_content, fn _tenant_id,
                                                                     _content,
                                                                     _opts ->
      {:ok, []}
    end)

    # Default stub for the memory-promotion LLM (Epic 29) -- returns a benign empty
    # JSON array so unrelated tests that trigger compile/2 don't fail. Individual
    # tests override with Mox.expect/3 to return crafted candidates.
    Mox.stub(Loopctl.MockPromoterLLM, :extract, fn _tenant_id, _content, _opts ->
      {:ok, "[]"}
    end)

    # Default stub for category classifier -- zero confidence, so the
    # reclassification backfill is a no-op unless a test sets its own verdict.
    Mox.stub(Loopctl.MockCategoryClassifier, :classify, fn _tenant_id, _title, _body, _opts ->
      {:ok, %{category: :pattern, confidence: 0.0}}
    end)

    # Default Req.Test stub for content ingestion URL fetching
    Req.Test.stub(Loopctl.Workers.ContentIngestionWorker, fn conn ->
      Req.Test.text(conn, "Default ingestion stub content")
    end)

    # Default Req.Test stub for webhook delivery -- allows Oban inline mode
    # to process delivery jobs without test-specific HTTP stub setup.
    Req.Test.stub(Loopctl.Webhooks.ReqDelivery, fn conn ->
      Req.Test.json(conn, %{"ok" => true})
    end)

    # US-27.15: webhook delivery DI (:webhook_delivery → Loopctl.MockDelivery in test).
    # Both ScaleAlerts and the webhook worker resolve this key. The DEFAULT delegates to
    # the real ReqDelivery (which honors the Req.Test plug above), so the existing
    # webhook-worker tests — which Req.Test.stub(Loopctl.Webhooks.ReqDelivery) — keep
    # working unchanged. ScaleAlerts tests override this with Mox.expect/3 to assert the
    # firing POST.
    Mox.stub(Loopctl.MockDelivery, :deliver, fn url, body, headers, scope ->
      ReqDelivery.deliver(url, body, headers, scope)
    end)

    # Default Req.Test stub for CLI HTTP client
    Req.Test.stub(Loopctl.CLI.Client, fn conn ->
      Req.Test.json(conn, %{"error" => "not stubbed"})
    end)

    # Default stub for WebAuthn adapter — returns a deterministic fake
    # registration challenge and a valid attestation result so tests that
    # touch signup without opting in still work.
    Mox.stub(Loopctl.MockWebAuthn, :new_registration_challenge, fn _opts ->
      %{bytes: <<0::256>>, rp_id: "localhost"}
    end)

    Mox.stub(Loopctl.MockWebAuthn, :verify_registration, fn payload, _challenge, _opts ->
      {:ok,
       %{
         credential_id: Map.get(payload, :credential_id) || :crypto.strong_rand_bytes(32),
         public_key: <<"stub-cose-key-", :rand.uniform(1_000_000)::32>>,
         attestation_format: "none",
         sign_count: 0
       }}
    end)

    Mox.stub(Loopctl.MockWebAuthn, :new_authentication_challenge, fn _opts ->
      %{bytes: <<0::256>>, rp_id: "localhost"}
    end)

    Mox.stub(Loopctl.MockWebAuthn, :verify_authentication, fn _payload, _challenge, _opts ->
      {:ok, %{sign_count: 1}}
    end)

    # Default stub for Secrets adapter — accepts all writes, returns :not_found on reads.
    Mox.stub(Loopctl.MockSecrets, :get, fn _name -> {:error, :not_found} end)
    Mox.stub(Loopctl.MockSecrets, :set, fn _name, _value -> :ok end)
    Mox.stub(Loopctl.MockSecrets, :delete, fn _name -> :ok end)

    # US-27.3: by default the suggested-links executor delegates to the real
    # context, so every existing suggest_links test exercises the genuine
    # pgvector query. Only the DB-error-surfacing test overrides this stub with
    # `Mox.expect/3` to inject a deterministic Postgrex.Error (a real
    # statement-timeout is timing-dependent and not reproducible here).
    Mox.stub(Loopctl.MockSuggestLinks, :suggest_links, fn tenant_id, article_id, opts ->
      Loopctl.Knowledge.suggest_links(tenant_id, article_id, opts)
    end)

    # US-27.6b: the controller calls the meta-bearing variant. Default stub
    # delegates to the real context so the endpoint exercises the genuine
    # under-fill detection unless a test overrides it with Mox.expect/3.
    Mox.stub(Loopctl.MockSuggestLinks, :suggest_links_with_meta, fn tenant_id, article_id, opts ->
      Loopctl.Knowledge.suggest_links_with_meta(tenant_id, article_id, opts)
    end)

    # Novelty-gated write-back: default to `:novel` so the gate is a no-op for the
    # existing article-create tests (they assert the normal create path). Tests that
    # exercise the gate override this with Mox.expect/3 to return a chosen verdict.
    Mox.stub(Loopctl.MockProposalAssessor, :assess, fn _tenant_id, _attrs, _opts ->
      %{verdict: :novel, score: nil, neighbors: []}
    end)

    # Merge synthesizer defaults to "no backend" so the conflict executor no-ops on
    # :merge rows unless a test opts in with a real merged result.
    Mox.stub(Loopctl.MockMergeSynthesizer, :synthesize, fn _tenant_id, _a, _b ->
      {:error, :not_configured}
    end)

    # US-30.3: Context-Retriever audit writer. The DEFAULT delegates to the real
    # Loopctl.Audit so every existing executor test writes and reads back a genuine
    # audit row unchanged. The fail-closed test overrides this with Mox.expect/3 to
    # return {:error, _} and assert run/3 returns {:error, :audit_failed}.
    Mox.stub(Loopctl.ContextRetriever.MockAudit, :create_log_entry, fn tenant_id, attrs ->
      Loopctl.Audit.create_log_entry(tenant_id, attrs)
    end)

    # Epic 28 (#179): default Req.Test stub for the shared tenant-scoped Anthropic
    # client. Returns an empty-articles Messages response with a zero-usage block so
    # any incidental call to a REAL Claude module (only when a tenant key is
    # configured) is intercepted without a real API call. Dedicated LLM tests
    # override this to return crafted content + usage.
    Req.Test.stub(Loopctl.Llm.Anthropic, fn conn ->
      Req.Test.json(conn, %{
        "content" => [%{"type" => "text", "text" => "[]"}],
        "usage" => %{"input_tokens" => 0, "output_tokens" => 0}
      })
    end)

    # ArticleLinkingWorker similarity lookup: default to NO candidates so unrelated tests
    # (and the inline-Oban embedding→linking cascade an article create/publish triggers)
    # behave exactly as before — a real vector search over a fresh corpus finds nothing to
    # link. Tests that assert linking override this with `Mox.expect/3` returning crafted
    # candidate maps. This keeps the worker off the timed heavy-read path in every test.
    Mox.stub(Loopctl.MockArticleSimilaritySearch, :nearest, fn _tenant_id,
                                                               _embedding,
                                                               _k,
                                                               _opts ->
      []
    end)

    # SSRF egress guard (ie-02 / worker-01): default-resolve any bare hostname to a
    # public, routable IP so existing example.com-based webhook and content-ingestion
    # tests pass unchanged. IP-literal cases bypass DNS entirely; the DNS-rebinding
    # tests override this with Mox.expect/3 to return a private address.
    Mox.stub(Loopctl.MockDnsResolver, :resolve, fn _host ->
      {:ok, [{93, 184, 216, 34}]}
    end)

    # US-27.3: the DBErrorBackstop test seam (Loopctl.Test.BackstopRouter) is a
    # REAL plug wired via config/test.exs that delegates to LoopctlWeb.Router for
    # every request and only raises when an opt-in `x-test-raise-db-error` header
    # is present — so there is NO global router mock to stub here.
  end

  @doc """
  A helper that transforms changeset errors into a map of messages.

      assert {:error, changeset} = Accounts.create_user(%{password: "short"})
      assert "password is too short" in errors_on(changeset).password
      assert %{password: ["password is too short"]} = errors_on(changeset)

  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  # A DETERMINISTIC per-TENANT embedding for the default MockEmbeddingClient stubs
  # (stub_all_defaults/0). Returns a 1536-dim vector that is a PURE FUNCTION of the
  # `tenant_id`, so every tenant occupies its own well-separated point in the
  # shared pgvector HNSW index while every text WITHIN a tenant maps to the SAME
  # vector. That separation is what keeps the index navigable (no global all-ties
  # clique → the issue-#421 recall flake disappears), and the within-tenant
  # sameness is what preserves the permissive default's existing semantics: a
  # recall in a tenant matches any of that tenant's memories regardless of query
  # text, so no recall test needs to set explicit embeddings. Sixteen
  # hash-selected dimensions are set so two tenants collide only if all sixteen
  # independent hashes collide (negligible). A non-binary input still hashes fine
  # via :erlang.phash2/1.
  defp deterministic_embedding(tenant_id) do
    hot = for salt <- 0..15, into: MapSet.new(), do: rem(:erlang.phash2({tenant_id, salt}), 1536)
    Enum.map(0..1535, fn i -> if MapSet.member?(hot, i), do: 1.0, else: 0.0 end)
  end
end
