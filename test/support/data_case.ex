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
  alias Loopctl.Embeddings.LegacyRetirement
  alias Loopctl.Embeddings.SystemConfigReadPath
  alias Loopctl.Knowledge.StreamingExport.NoopBodyProbe
  alias Loopctl.Knowledge.StructuralLinks
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
    if tags[:vacuum_vector_indexes], do: Loopctl.DataCase.vacuum_vector_indexes()
    Loopctl.DataCase.setup_sandbox(tags)
    Mox.set_mox_from_context(tags)
    stub_all_defaults()
    # Per-test embedding axis: every test gets a UNIQUE integer, so `test_vec/2` hashes
    # this test's vectors onto its own sparse dimensions of the shared pgvector HNSW index.
    # Setup runs in the test process, so `Process.get(:test_vec_axis)` at insert time sees it.
    Process.put(:test_vec_axis, System.unique_integer([:positive]))
    :ok
  end

  # Tables carrying a pgvector HNSW index. Vacuuming these is what removes dead index
  # entries from the graph; the two side tables are where the flake actually bit, and the
  # two legacy ones carry indexes over the pre-cutover `embedding` columns.
  @vector_tables ~w(article_embeddings memory_embeddings articles memories)

  @doc """
  Removes dead pgvector HNSW entries left in the shared index graph by rolled-back tests
  (#645). Opt in per module with `@moduletag :vacuum_vector_indexes`.

  ## Why a test suite has to do this at all

  Sandbox rolls back every test, and a rolled-back INSERT leaves its HNSW entry in the
  graph until vacuum. A row inserted afterwards links to its nearest neighbours — which by
  then are all DEAD elements — and pgvector's scan SKIPS dead elements rather than
  traversing through them. The live row ends up UNREACHABLE from the graph entry point, so
  an ANN read returns NOTHING while a `count()` on the same connection shows the row
  present. That is the long-running `left: []` flake, reproduced deterministically in
  `test/loopctl/embeddings/hnsw_dead_entry_recall_test.exs`.

  It is a REACHABILITY failure, not a breadth one, which is why `hnsw.ef_search`,
  `hnsw.iterative_scan` and exact-scan forcing each failed to fix it: measured in that
  file, the read still returns `[]` under `relaxed_order` AND under `ef_search = 1000`.
  Vacuuming is the only thing that repairs the graph, and it repairs it completely — the
  same poisoned index answers correctly immediately afterwards.

  Production is not affected: its rows are committed, so its graph is not made of dead
  entries.

  Runs unboxed (VACUUM cannot run inside a transaction) and never fails a test: a vacuum
  that cannot run leaves the suite exactly as flaky as it was before, which is a worse
  outcome to hide behind an exception than to carry on with.
  """
  @spec vacuum_vector_indexes() :: :ok
  def vacuum_vector_indexes do
    Sandbox.unboxed_run(Loopctl.AdminRepo, fn ->
      for table <- @vector_tables do
        Loopctl.AdminRepo.query!("VACUUM (INDEX_CLEANUP ON) #{table}", [])
      end
    end)

    :ok
  rescue
    error ->
      require Logger

      Logger.warning(
        "vacuum_vector_indexes failed (#{inspect(error.__struct__)}) — ANN recall in this " <>
          "module is unprotected against dead HNSW entries (#645)"
      )

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
  US-41.1: default the injected read-path decision to the REAL SystemConfig-backed
  implementation, so a test sees production behaviour (legacy column until an operator
  flips the flag). The US-41.1 read-path tests override this with a process-scoped
  `Mox.stub/3` instead of mutating the VM-global flag.

  `config/test.exs` points `:embedding_read_path` at `Loopctl.MockEmbeddingReadPath` for
  the WHOLE test env, so ANY test that reaches `Loopctl.Embeddings.side_table_reads_enabled?/0`
  needs this stub — including tests that do NOT `use Loopctl.DataCase`/`ConnCase` (the
  `:scale`/`:scale_nightly` modules on bare `ExUnit.Case`), which would otherwise raise
  `Mox.UnexpectedCallError` in the nightly job instead of reading the flag. Those modules
  call this directly from their own `setup`; `stub_all_defaults/0` calls it for everyone else.
  """
  def stub_embedding_read_path do
    Mox.stub(Loopctl.MockEmbeddingReadPath, :side_table_reads_enabled?, fn ->
      SystemConfigReadPath.side_table_reads_enabled?()
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

    stub_embedding_read_path()

    # #558: default to the REAL count, so every existing fair-share test (which seeds real
    # oban_jobs rows in its own sandboxed transaction) is unaffected. Only the fail-open test
    # overrides it to EXIT — the one shape a sandboxed pool cannot produce, and the reason
    # this gate shipped failing CLOSED.
    Mox.stub(
      Loopctl.MockFairShareCounter,
      :lower_ranked_executing_count,
      &FairShare.lower_ranked_executing_count/3
    )

    # GH #551: production behaviour by default — the retirement trigger really probes,
    # records and evaluates. Only the worker's fail-closed test overrides `probe/0` to
    # return an error, which is the one shape the test database cannot produce.
    Mox.stub(Loopctl.MockLegacyRetirement, :probe, fn -> LegacyRetirement.probe() end)

    Mox.stub(Loopctl.MockLegacyRetirement, :observations_table_ready?, fn ->
      LegacyRetirement.observations_table_ready?()
    end)

    Mox.stub(Loopctl.MockLegacyRetirement, :record, &LegacyRetirement.record/2)
    Mox.stub(Loopctl.MockLegacyRetirement, :evaluate, &LegacyRetirement.evaluate/2)

    # #725: default to the REAL harvest, so the StructuralLinksWorker tests exercise the
    # genuine hub/edge writes in their own sandboxed transaction. Only the shed test
    # overrides this, with `{:error, :heavy_read_overloaded}` — a shed the test pool
    # cannot produce, and the branch whose absence would crash the worker under exactly
    # the load the shedder exists to relieve.
    Mox.stub(Loopctl.MockStructuralLinksHarvester, :harvest, &StructuralLinks.harvest/2)

    # US-27.16: default to PRODUCTION behaviour — the streaming-export producer observes
    # (and therefore retains) nothing. Only the bounded-memory scale gate overrides this,
    # with a retaining closure, to prove its metric catches a materializing producer.
    Mox.stub(Loopctl.MockStreamingExportBodyProbe, :probe, fn ->
      &NoopBodyProbe.ignore/1
    end)

    # Shape MUST match `Loopctl.HealthCheck.Default.check/0`. It notably carries NO
    # `version` key: #461 item 5 removed the app version from this response on purpose,
    # because /health is the highest-frequency unauthenticated probe and there is no
    # reason to hand a version fingerprint to every caller. The stub used to return
    # `version: "0.1.0-test"`, so every test asserting on the health payload was
    # asserting against a field the real endpoint deliberately does not emit — a test
    # double that quietly re-adds what production removed cannot catch its removal
    # regressing.
    Mox.stub(Loopctl.MockHealthChecker, :check, fn ->
      {:ok,
       %{
         status: "ok",
         ready: true,
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

  # The per-test embedding window width: each test claims `@test_vec_window` hot dimensions
  # for `:primary` and another `@test_vec_window` (disjoint) for `:orthogonal`, all selected
  # by INDEPENDENT hashes of the test's unique axis (see `test_vec/2`).
  @test_vec_window 8

  @doc """
  Per-test-unique embedding vector for pgvector recall tests.

  The shared, cross-tenant pgvector HNSW index (`article_embeddings` / `memory_embeddings`)
  is a single physical structure. When many tests seed the SAME fixed vector (e.g. a
  `half_ones` `[1×768, 0×768]`), those identical rows — live in-transaction plus
  rolled-back-but-unvacuumed dead tuples across a full suite — form an all-ties CLIQUE the
  approximate ANN graph walk cannot navigate, so a genuinely-near neighbour is intermittently
  evicted before the tenant filter runs. That is the shared-index recall flake (issue #421 /
  the AC-41.1.5 side-table ranking flake).

  Keying each test's vectors on its unique `:test_vec_axis` (set in setup) into SPARSE,
  hash-selected dimensions is what breaks the cross-test clique — without crowding (a dense
  per-test rotation was tried and FAILS: rotated dense vectors sit nearer the query than a
  0.71 neighbour and fill the `ef_search` budget). Within a single test the geometry is
  preserved exactly: `:primary`/`:query`/`:close` are identical (cosine 1.0), `:near` is half
  the primary dimensions (cosine ~0.71), and `:orthogonal` shares NO dimension with `:primary`
  (cosine 0).

  ## What the cross-test guarantee actually is

  The hot dimensions are `@test_vec_window` INDEPENDENT hashes of the axis, drawn from the
  full `dim` range — NOT `rem(axis, dim / 16)` window slots, which pigeonholed the whole suite
  into 96 windows at 1536-dim and made byte-identical vectors (the all-ties clique) a ~25%
  birthday event between two concurrently-running tests. Precisely:

    * two tests produce IDENTICAL vectors only if all #{@test_vec_window} independent hashes collide —
      negligible, and identity is the shape that recreates the clique;
    * an incidental single-dimension overlap between two tests is possible (~1% per pair) and
      is harmless: it yields cosine 1/#{@test_vec_window} = 0.125, far below the ~0.71 `:near` neighbour the
      recall assertions rank against.

  Do NOT reintroduce a fixed/global vector here, and do not "simplify" the hashing back to a
  modular window index — dissolving the shared-HNSW-index clique is the entire point.

  Requires `dim >= 2 * #{@test_vec_window}` so the primary and orthogonal dimension sets can be disjoint.

  Kinds (aliases group by MEANING so call sites read naturally):

    * `:primary` | `:query` | `:close` | `:self` | `:similar` | `:base` — the primary dimensions
    * `:near` — half the primary dimensions (a strictly-worse but genuinely-near neighbour, ~0.71)
    * `:orthogonal` | `:secondary` | `:dissimilar` | `:complement` — the disjoint set (⊥ primary)
  """
  @spec test_vec(pos_integer(), atom()) :: [float()]
  def test_vec(dim, kind \\ :primary) when is_integer(dim) do
    if dim < @test_vec_window * 2 do
      raise ArgumentError,
            "test_vec/2 needs dim >= #{@test_vec_window * 2} to keep :primary and :orthogonal " <>
              "disjoint, got #{dim}"
    end

    axis = Process.get(:test_vec_axis, 0)
    {primary, orthogonal} = Enum.split(test_vec_dims(axis, dim), @test_vec_window)

    hot =
      case kind do
        k when k in [:primary, :query, :close, :self, :similar, :base] ->
          primary

        :near ->
          Enum.take(primary, div(@test_vec_window, 2))

        k when k in [:orthogonal, :secondary, :dissimilar, :complement] ->
          orthogonal
      end

    test_vec_ones(dim, hot)
  end

  # `2 * @test_vec_window` DISTINCT dimensions, a deterministic pure function of the axis.
  # Each is its own `:erlang.phash2/1` over `{axis, salt}`, so the sets of two different
  # axes coincide only on a multi-way hash collision.
  defp test_vec_dims(axis, dim) do
    0
    |> Stream.iterate(&(&1 + 1))
    |> Stream.map(&rem(:erlang.phash2({:test_vec, axis, &1}), dim))
    |> Stream.uniq()
    |> Enum.take(@test_vec_window * 2)
  end

  defp test_vec_ones(dim, hot) do
    set = MapSet.new(hot)
    Enum.map(0..(dim - 1), fn i -> if MapSet.member?(set, i), do: 1.0, else: 0.0 end)
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
