defmodule Loopctl.Knowledge.HybridE2ETest do
  @moduledoc """
  US-31.5: terminal end-to-end verification for Epic 31 (the OKF-curated + RAG
  hybrid knowledge retrieval interface, GitHub issues #305/#306 — the SAME
  feature). Writes NO new production feature code; proves the epic's acceptance
  across every surface in one place.

  - **TC-31.5.1** (end-to-end + negative control): a governed curated
    refund-policy article suppresses an unrelated fuzzy chunk (`:curated`,
    hoisted first, flagged); removing ONLY the curated article from the SAME
    corpus (the unrelated chunk untouched) flips the result to `:retrieved` and
    surfaces the previously-suppressed chunk — proving the curated article, not
    some other corpus property, is what suppressed it. A niche non-curated
    topic falls to `:retrieved`. A near-but-wrong curated doc below threshold is
    never mislabeled `:curated`.
  - **TC-31.5.1(c)** shape parity: `:curated`/`:retrieved` meta share an
    identical key set — a caller branches on `meta.provenance` alone, never on
    which subsystem answered.
  - **AC-31.5.3 / TC-31.5.2**: tenant isolation across every surface (resolver,
    progressive index/drill, HTTP API — MCP scope-blindness for these same tools
    is proven in `mcp-server/test/knowledge_tools.test.js`, US-31.4, which
    asserts no `tenant_id` parameter is ever accepted and every call dispatches
    to the tenant-scoped HTTP endpoint under the caller's own key). A
    system-scoped curated article participates in the resolver's curated
    identification without overriding a tenant's own. A conflicted curated
    article is never returned as authoritative without the conflict being
    surfaced.

  This does NOT duplicate `test/loopctl/knowledge_hybrid_test.exs` (US-31.2
  resolver unit/integration coverage), `test/loopctl/knowledge_curated_test.exs`
  (US-31.1 governance/precedence unit coverage), or
  `test/loopctl/knowledge/progressive_index_test.exs` (US-31.3 index/drill unit
  coverage) — those remain the detailed per-unit proofs; this file is the
  epic-wide E2E proof, with the negative control those files do not carry.

  Setup helpers are copied verbatim from `test/loopctl/knowledge_hybrid_test.exs`.
  """
  use LoopctlWeb.ConnCase, async: true

  setup :verify_on_exit!

  alias Loopctl.Knowledge
  alias Loopctl.Knowledge.Article

  # A "direction" + a midpoint, mirroring knowledge_hybrid_test.exs /
  # knowledge_semantic_search_test.exs: cosine of identical directions is 1.0, and the
  # midpoint sits at ~0.71 — safely below the 0.75 default threshold while still a genuinely
  # near (not orthogonal) chunk. Sourced per-test from `Loopctl.DataCase.test_vec/2`
  # (functions, not compile-time attributes) so each test's vectors occupy a DISJOINT window
  # of the shared HNSW index — dissolving the all-ties clique that flakes recall.
  defp direction_a, do: test_vec(1536, :primary)
  defp direction_medium, do: test_vec(1536, :near)

  defp auth_conn(conn, raw_key) do
    put_req_header(conn, "authorization", "Bearer #{raw_key}")
  end

  # Creates a published tenant article and marks it curated via the governed path.
  defp curated_article(tenant_id, attrs) do
    article =
      fixture(:article, Map.merge(%{tenant_id: tenant_id, status: :published}, attrs))

    {:ok, marked} = Knowledge.mark_curated(tenant_id, article.id, actor_label: "user:admin")
    marked
  end

  defp set_embedding(tenant_id, article, vector) do
    {:ok, updated} = Knowledge.update_embedding(tenant_id, article.id, vector)
    updated
  end

  # Stubs the embedding client to return a specific vector per exact query text,
  # falling back to the DataCase default (uniform 0.1 vector) for any other text.
  defp stub_embeddings_by_query(mapping) do
    Mox.stub(Loopctl.MockEmbeddingClient, :generate_embedding, fn _tenant_id, text ->
      case Map.fetch(mapping, text) do
        {:ok, vector} -> {:ok, vector}
        :error -> {:ok, List.duplicate(0.1, 1536)}
      end
    end)
  end

  defp relates_to(tenant_id, source, target) do
    fixture(:article_link, %{
      tenant_id: tenant_id,
      source_article_id: source.id,
      target_article_id: target.id,
      relationship_type: :relates_to
    })
  end

  # --- TC-31.5.1: end-to-end with negative control ---

  describe "hybrid_search/3 - refund-policy negative control (TC-31.5.1)" do
    test "curated wins when present; removing it from the SAME corpus surfaces the suppressed chunk" do
      tenant = fixture(:tenant)
      Knowledge.reset_circuit_breaker(tenant.id)

      curated =
        tenant.id
        |> curated_article(%{
          title: "Refund Policy Guide",
          body: "Our refund policy allows returns within 30 days for a full refund."
        })
        |> then(&set_embedding(tenant.id, &1, direction_a()))

      # A fuzzy, non-curated chunk that sits NEAR the query in embedding space
      # (direction_medium(), ~0.7033 cosine to the query — the same near-miss
      # vector used by the below-threshold test further down) rather than
      # orthogonal to it. This is what docs/knowledge-hybrid-retrieval.md:20-26
      # actually describes as the harvested failure: a chunk close enough that
      # naive RAG search surfaces it with substantial confidence, not a
      # zero-similarity chunk that would honestly show up as low-confidence on
      # its own. It is never touched by the negative control below, so any
      # change in outcome is attributable ONLY to the curated article's
      # presence/absence.
      unrelated =
        fixture(:article, %{
          tenant_id: tenant.id,
          title: "Shipping Timelines",
          body: "How long orders take to ship across different carriers.",
          status: :published
        })
        |> then(&set_embedding(tenant.id, &1, direction_medium()))

      query = "refund policy"
      stub_embeddings_by_query(%{query => direction_a()})

      # (a) WITH the curated article present: it wins :curated, is hoisted to
      # the front, and the unrelated chunk is NOT what the caller is handed as
      # the answer.
      assert {:ok, %{results: with_curated, meta: meta_with_curated}} =
               Knowledge.hybrid_search(tenant.id, query, keyword_weight: 0, semantic_weight: 1)

      assert meta_with_curated.provenance == :curated
      assert meta_with_curated.curated_article_id == curated.id
      assert List.first(with_curated).id == curated.id
      refute meta_with_curated.curated_article_id == unrelated.id

      # (d) NEGATIVE CONTROL — the SAME corpus, with ONLY the curated article now
      # ABSENT (archived: excluded from the published search pool, same as if the
      # governed answer had never been written). This is the literal harvested
      # failure this epic exists to prevent: with no governed answer, the
      # semantically-near (~0.7033 cosine, below the 0.75 curated threshold but
      # far from zero) chunk becomes the best available answer, surfaced at
      # substantial confidence — honestly labeled :retrieved, never silently
      # trusted as :curated.
      assert {:ok, _archived} = Knowledge.archive_article(tenant.id, curated.id)

      assert {:ok, %{results: without_curated, meta: meta_without_curated}} =
               Knowledge.hybrid_search(tenant.id, query, keyword_weight: 0, semantic_weight: 1)

      assert meta_without_curated.provenance == :retrieved
      assert meta_without_curated.curated_article_id == nil
      assert List.first(without_curated).id == unrelated.id
    end

    test "a long-tail/niche query with no curated coverage at all falls to :retrieved" do
      tenant = fixture(:tenant)
      Knowledge.reset_circuit_breaker(tenant.id)

      fixture(:article, %{
        tenant_id: tenant.id,
        title: "Niche Topic Deep Dive",
        body: "A very niche topic with no curated coverage whatsoever.",
        status: :published
      })

      assert {:ok, %{results: results, meta: meta}} =
               Knowledge.hybrid_search(tenant.id, "niche topic")

      assert results != []
      assert meta.provenance == :retrieved
      assert meta.curated_article_id == nil
    end

    test "a near-but-wrong curated doc below threshold is never mislabeled :curated" do
      tenant = fixture(:tenant)
      Knowledge.reset_circuit_breaker(tenant.id)

      near_but_wrong =
        tenant.id
        |> curated_article(%{title: "Shipping Refund Process"})
        |> then(&set_embedding(tenant.id, &1, direction_medium()))

      query = "what is the refund policy?"
      stub_embeddings_by_query(%{query => direction_a()})

      assert {:ok, %{results: results, meta: meta}} =
               Knowledge.hybrid_search(tenant.id, query, keyword_weight: 0, semantic_weight: 1)

      # Still findable (retrieval is honest that it exists)...
      assert Enum.any?(results, &(&1.id == near_but_wrong.id))
      # ...but never trusted as the authoritative curated answer -- its absolute
      # cosine similarity to the query (~0.7033) sits below the 0.75 threshold.
      assert meta.provenance == :retrieved
      refute meta.curated_article_id == near_but_wrong.id
    end
  end

  # --- TC-31.5.1(c): shape parity / no caller-side branching ---

  describe "hybrid_search/3 - shape parity (TC-31.5.1c)" do
    test "curated and retrieved meta share an identical key set" do
      curated_tenant = fixture(:tenant)
      Knowledge.reset_circuit_breaker(curated_tenant.id)

      curated = curated_article(curated_tenant.id, %{title: "Deploy Guide Curated"})
      set_embedding(curated_tenant.id, curated, direction_a())
      stub_embeddings_by_query(%{"deploy guide" => direction_a()})

      assert {:ok, %{meta: curated_meta}} =
               Knowledge.hybrid_search(curated_tenant.id, "deploy guide",
                 keyword_weight: 0,
                 semantic_weight: 1
               )

      assert curated_meta.provenance == :curated

      retrieved_tenant = fixture(:tenant)
      Knowledge.reset_circuit_breaker(retrieved_tenant.id)

      fixture(:article, %{
        tenant_id: retrieved_tenant.id,
        title: "Niche Article",
        body: "A niche topic nobody has curated an answer for.",
        status: :published
      })

      assert {:ok, %{meta: retrieved_meta}} =
               Knowledge.hybrid_search(retrieved_tenant.id, "niche topic")

      assert retrieved_meta.provenance == :retrieved
      assert Enum.sort(Map.keys(curated_meta)) == Enum.sort(Map.keys(retrieved_meta))

      for key <- [:provenance, :confidence, :search_mode, :curated_article_id] do
        assert Map.has_key?(curated_meta, key)
        assert Map.has_key?(retrieved_meta, key)
      end
    end
  end

  # --- AC-31.5.3 / TC-31.5.2: tenant isolation across every surface ---

  describe "hybrid_search/3 - tenant isolation (context surface, TC-31.5.2)" do
    test "tenant B never sees tenant A's curated content, even against a populated pool" do
      tenant_a = fixture(:tenant)
      Knowledge.reset_circuit_breaker(tenant_a.id)

      secret =
        tenant_a.id
        |> curated_article(%{
          title: "Tenant A Refund Policy",
          body: "Tenant A's confidential refund policy details."
        })
        |> then(&set_embedding(tenant_a.id, &1, direction_a()))

      # tenant_b is seeded with its OWN decoy on the SAME axis, so this proves
      # tenant A's curated article does not intermingle into a populated tenant
      # B result set (stronger than an empty pool, which would pass even if
      # tenant-scoping logic were broken).
      tenant_b = fixture(:tenant)
      Knowledge.reset_circuit_breaker(tenant_b.id)

      decoy =
        tenant_b.id
        |> curated_article(%{
          title: "Tenant B Refund Policy",
          body: "Tenant B's own refund policy on the same axis as tenant A's."
        })
        |> then(&set_embedding(tenant_b.id, &1, direction_a()))

      query = "refund policy"
      stub_embeddings_by_query(%{query => direction_a()})

      assert {:ok, %{results: results_b, meta: meta_b}} =
               Knowledge.hybrid_search(tenant_b.id, query, keyword_weight: 0, semantic_weight: 1)

      refute Enum.any?(results_b, &(&1.id == secret.id))
      assert meta_b.curated_article_id != secret.id
      assert meta_b.provenance == :curated
      assert meta_b.curated_article_id == decoy.id
    end
  end

  describe "progressive_index/drill - tenant isolation (progressive surface, TC-31.5.2)" do
    test "a tenant B index for tenant A's topic returns none of tenant A's stubs" do
      tenant_a = fixture(:tenant)
      topic = "HybridE2ETenantIsolatedTopicABCD"

      hub =
        fixture(:article, %{
          tenant_id: tenant_a.id,
          status: :published,
          title: "#{topic} Hub"
        })

      target_a = curated_article(tenant_a.id, %{title: "#{topic} Curated Target"})
      relates_to(tenant_a.id, hub, target_a)

      tenant_b = fixture(:tenant)

      assert {:ok, %{stubs: stubs_b}} = Knowledge.progressive_index(tenant_b.id, topic)
      assert stubs_b == []

      # Sanity: tenant_a genuinely sees its own stubs for the same topic.
      assert {:ok, %{stubs: stubs_a}} = Knowledge.progressive_index(tenant_a.id, topic)
      refute stubs_a == []
    end

    test "a tenant B drill on tenant A's article id is a clean not_found (no leak)" do
      tenant_a = fixture(:tenant)
      secret = curated_article(tenant_a.id, %{title: "Tenant A Progressive Secret"})

      tenant_b = fixture(:tenant)

      assert {:error, :not_found} = Knowledge.progressive_drill(tenant_b.id, secret.id)
      assert {:ok, _} = Knowledge.progressive_drill(tenant_a.id, secret.id)
    end
  end

  describe "POST hybrid_search - tenant isolation (HTTP API surface, TC-31.5.2)" do
    test "tenant B key never sees tenant A's curated content over the HTTP API", %{conn: conn} do
      tenant_a = fixture(:tenant)
      Knowledge.reset_circuit_breaker(tenant_a.id)

      secret =
        tenant_a.id
        |> curated_article(%{
          title: "Tenant A HTTP Refund Policy",
          body: "Tenant A's confidential refund policy details over HTTP."
        })
        |> then(&set_embedding(tenant_a.id, &1, direction_a()))

      tenant_b = fixture(:tenant)
      Knowledge.reset_circuit_breaker(tenant_b.id)
      {raw_key_b, _} = fixture(:api_key, %{tenant_id: tenant_b.id, role: :agent})

      decoy =
        tenant_b.id
        |> curated_article(%{
          title: "Tenant B HTTP Refund Policy",
          body: "Tenant B's own refund policy over HTTP."
        })
        |> then(&set_embedding(tenant_b.id, &1, direction_a()))

      query = "refund policy"
      stub_embeddings_by_query(%{query => direction_a()})

      conn =
        conn
        |> auth_conn(raw_key_b)
        |> post(~p"/api/v1/knowledge/hybrid_search", %{query: query})

      body = json_response(conn, 200)

      refute Enum.any?(body["data"], &(&1["id"] == secret.id))
      assert body["meta"]["curated_article_id"] != secret.id
      assert Enum.any?(body["data"], &(&1["id"] == decoy.id))
      assert body["meta"]["provenance"] == "curated"
      assert body["meta"]["curated_article_id"] == decoy.id
    end
  end

  # --- AC-31.5.3: system-scope precedence feeds the resolver's curated identification ---

  describe "hybrid_search/3 - system-scope precedence (AC-31.5.3)" do
    test "the resolver's :ids-restricted list_curated_sources/2 suppresses a same-topic system canonical" do
      tenant = fixture(:tenant)

      {:ok, system_article} =
        Knowledge.create_article(tenant.id, %{
          scope: :system,
          status: :published,
          category: :reference,
          title: "Shared Topic Answer",
          body: "system body"
        })

      {:ok, system} =
        Knowledge.mark_curated(nil, system_article.id, actor_label: "superadmin", scope: :system)

      tenant_own =
        curated_article(tenant.id, %{title: "Shared Topic Answer", body: "tenant body"})

      # This is the EXACT call hybrid_search/3's internal curated_source_ids/2
      # makes (select: :id, ids: the caller's own search pool) — proving the
      # dependency the resolver relies on for system-scope precedence.
      assert Knowledge.list_curated_sources(tenant.id,
               select: :id,
               ids: [tenant_own.id, system.id]
             ) == [tenant_own.id]

      # A system canonical on a DIFFERENT topic the tenant has not curated still
      # participates when it is in the pool (it does not vanish outright).
      {:ok, system_only_article} =
        Knowledge.create_article(tenant.id, %{
          scope: :system,
          status: :published,
          category: :reference,
          title: "System-Only Topic",
          body: "system only body"
        })

      {:ok, system_only} =
        Knowledge.mark_curated(nil, system_only_article.id,
          actor_label: "superadmin",
          scope: :system
        )

      assert Knowledge.list_curated_sources(tenant.id, select: :id, ids: [system_only.id]) == [
               system_only.id
             ]
    end
  end

  # --- AC-31.5.3: a conflicted curated article is never returned as authoritative ---

  describe "hybrid_search/3 - a conflicted curated article is never authoritative (AC-31.5.3)" do
    test "an open-conflict curated article, even with a high embedding match, falls to :retrieved" do
      tenant = fixture(:tenant)
      Knowledge.reset_circuit_breaker(tenant.id)

      conflicted =
        tenant.id
        |> curated_article(%{title: "Conflicted Curated Answer"})
        |> then(&set_embedding(tenant.id, &1, direction_a()))

      rival =
        fixture(:article, %{tenant_id: tenant.id, status: :published, title: "Rival Answer"})

      fixture(:article_link, %{
        tenant_id: tenant.id,
        source_article_id: conflicted.id,
        target_article_id: rival.id,
        relationship_type: :potential_conflict,
        metadata: %{"auto_generated" => true, "similarity_score" => 0.95}
      })

      query = "conflicted curated answer topic"
      stub_embeddings_by_query(%{query => direction_a()})

      assert {:ok, %{results: results, meta: meta}} =
               Knowledge.hybrid_search(tenant.id, query, keyword_weight: 0, semantic_weight: 1)

      # Still genuinely findable via retrieval (a real, high-similarity match)...
      assert Enum.any?(results, &(&1.id == conflicted.id))
      # ...but NEVER labeled the authoritative curated answer while the conflict
      # is open. The conflict must be resolved through
      # `knowledge_resolve_conflict` first -- it is not silently papered over.
      assert meta.provenance == :retrieved
      assert meta.curated_article_id == nil
    end

    test "a superseded curated article is structurally excluded from the search pool and never authoritative" do
      tenant = fixture(:tenant)
      Knowledge.reset_circuit_breaker(tenant.id)

      marked =
        curated_article(tenant.id, %{title: "Superseded Curated Answer", body: "old answer"})

      _superseded =
        marked
        |> Article.curation_changeset(marked.curated_at, marked.curated_by)
        |> Ecto.Changeset.change(status: :superseded)
        |> Loopctl.AdminRepo.update!()

      assert {:ok, %{meta: meta}} =
               Knowledge.hybrid_search(tenant.id, "superseded curated answer")

      assert meta.provenance == :retrieved
      assert meta.curated_article_id == nil
    end
  end
end
