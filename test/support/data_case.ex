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
    Mox.stub(Loopctl.MockHealthChecker, :check, fn ->
      {:ok,
       %{
         status: "ok",
         version: "0.1.0-test",
         checks: %{database: "ok", oban: "ok"}
       }}
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

    # Default stub for embedding client -- returns a 1536-dim vector of 0.1
    Mox.stub(Loopctl.MockEmbeddingClient, :generate_embedding, fn _text ->
      {:ok, List.duplicate(0.1, 1536)}
    end)

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
    Mox.stub(Loopctl.MockDelivery, :deliver, fn url, body, headers ->
      ReqDelivery.deliver(url, body, headers)
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
end
