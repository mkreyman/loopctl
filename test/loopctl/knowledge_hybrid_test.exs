defmodule Loopctl.KnowledgeHybridTest do
  @moduledoc """
  US-31.2: Hybrid resolver — prefer curated ONLY when it actually answers, else
  retrieval, with provenance.

  Covers `Knowledge.hybrid_search/3` (composing the already-shipped
  `search_combined/3` retrieval and `list_curated_sources/2` curated-identification
  subsystems, US-31.1) and the pure `Knowledge.resolve_provenance/4` decision rule.
  """
  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  alias Loopctl.AdminRepo
  alias Loopctl.Knowledge
  alias Loopctl.Knowledge.ArticleAccessEvent

  # Two orthogonal "directions" + a midpoint, mirroring the pattern in
  # knowledge_semantic_search_test.exs: cosine similarity of identical directions is
  # 1.0, orthogonal directions is 0.0, and the midpoint sits at ~0.7033 to either —
  # deterministic enough to sit safely below the 0.75 default threshold without
  # floating-point flakiness.
  @direction_a List.duplicate(1.0, 768) ++ List.duplicate(0.0, 768)
  @direction_b List.duplicate(0.0, 768) ++ List.duplicate(1.0, 768)
  @direction_medium List.duplicate(0.5, 768) ++ List.duplicate(0.5, 768)

  # Creates a published tenant article and marks it curated via the governed path
  # (mirrors test/loopctl/knowledge_curated_test.exs).
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

  # --- TC-31.2.1: curated that answers wins; near-but-wrong curated does NOT ---

  describe "hybrid_search/3 - curated that answers wins; near-but-wrong curated does NOT (TC-31.2.1)" do
    test "the answering curated article wins :curated; a different curated doc only loosely related to another query falls to :retrieved" do
      tenant = fixture(:tenant)
      Knowledge.reset_circuit_breaker(tenant.id)

      answering =
        tenant.id
        |> curated_article(%{title: "Refund Policy Answer"})
        |> then(&set_embedding(tenant.id, &1, @direction_a))

      _near_but_wrong =
        tenant.id
        |> curated_article(%{title: "Shipping Refund Process"})
        |> then(&set_embedding(tenant.id, &1, @direction_medium))

      # A non-curated distractor exactly aligned with `other_query`'s embedding —
      # the genuine best-retrieved competitor `other_query` must fall back to,
      # proving the near-but-wrong curated doc is beaten on merit, not by default.
      _distractor =
        fixture(:article, %{
          tenant_id: tenant.id,
          title: "Unrelated Distractor",
          status: :published
        })
        |> then(&set_embedding(tenant.id, &1, @direction_b))

      answering_query = "what is the refund policy?"
      other_query = "a query only loosely related to shipping refunds"

      stub_embeddings_by_query(%{answering_query => @direction_a, other_query => @direction_b})

      assert {:ok, %{results: results1, meta: meta1}} =
               Knowledge.hybrid_search(tenant.id, answering_query,
                 keyword_weight: 0,
                 semantic_weight: 1
               )

      assert meta1.provenance == :curated
      assert Enum.any?(results1, &(&1.id == answering.id))

      assert {:ok, %{meta: meta2}} =
               Knowledge.hybrid_search(tenant.id, other_query,
                 keyword_weight: 0,
                 semantic_weight: 1
               )

      assert meta2.provenance == :retrieved
    end
  end

  # --- Regression (review finding 1/2): a LONE/top curated candidate must NOT win
  # :curated just because it is the only thing in the pool. Removing TC-31.2.1's
  # non-curated distractor is the exact scenario the original review flagged: without
  # a competitor, min-max normalization used to force this doc's score to 1.0
  # regardless of its true (sub-threshold) cosine similarity.

  describe "hybrid_search/3 - lone curated candidate, weak similarity (finding 1/2 regression)" do
    test "the ONLY pool candidate, with cosine below threshold, does not win :curated by normalizing to 1.0" do
      tenant = fixture(:tenant)
      Knowledge.reset_circuit_breaker(tenant.id)

      weak_curated =
        tenant.id
        |> curated_article(%{title: "Shipping Refund Process"})
        |> then(&set_embedding(tenant.id, &1, @direction_medium))

      query = "what is the refund policy?"
      stub_embeddings_by_query(%{query => @direction_a})

      assert {:ok, %{results: results, meta: meta}} =
               Knowledge.hybrid_search(tenant.id, query, keyword_weight: 0, semantic_weight: 1)

      assert Enum.any?(results, &(&1.id == weak_curated.id))
      assert meta.provenance == :retrieved

      # meta.confidence is scoped to the :retrieved provenance CLASS (finding: a
      # :retrieved response must never report a rejected CURATED candidate's score as
      # if it belonged to a genuine retrieval winner — a different provenance class).
      # Here the sole pool candidate is the rejected curated article itself, so there
      # is no genuine non-curated competitor at all: confidence is honestly 0.0, even
      # though `results` still (correctly) surfaces that below-threshold article as
      # the best answer we have.
      assert meta.confidence == 0.0
    end
  end

  # --- Regression (review finding 4, later hardened by the "label != payload"
  # hoist-to-front fix): the curated/retrieved decision must be resolved over the top
  # of the RANKED POOL, independent of the caller's `:limit`/`:offset` page window — a
  # curated source that answers but ranks outside the default page must still be
  # identified. Once identified, the winning curated article is additionally hoisted
  # to the FRONT of the (still full) pool BEFORE pagination — never left as a mere
  # label with no corresponding payload in `results` — so `meta.provenance ==
  # :curated` always means `results |> List.first()` (at the default `offset: 0`) IS
  # that curated answer, never one of the keyword-heavy decoys that merely out-ranked
  # it on the pool-relative `:final_score`.

  describe "hybrid_search/3 - resolved over pool, curated winner hoisted to front (finding 4 + decoy fix)" do
    test "a curated source ranked outside the default page is identified AND hoisted to front; a deeper offset never re-surfaces it" do
      tenant = fixture(:tenant)
      Knowledge.reset_circuit_breaker(tenant.id)

      query = "invoice generation troubleshooting steps"

      # 12 non-curated decoys: STRONG keyword match (identical relevant terms, so ts_rank
      # is identical across all of them) but a FAR/orthogonal embedding (cosine 0 to the
      # query embedding) — with keyword weighted heavily, every decoy outranks the
      # curated doc in the merged/combined pool ordering.
      for i <- 1..12 do
        fixture(:article, %{
          tenant_id: tenant.id,
          status: :published,
          title: "Invoice Generation Troubleshooting Guide #{i}",
          body:
            "Invoice generation troubleshooting steps for common invoice generation issues. " <>
              "Invoice generation troubleshooting requires careful invoice generation review."
        })
        |> then(&set_embedding(tenant.id, &1, @direction_b))
      end

      # The curated doc shares NO keyword terms with the query at all (so it never
      # enters the keyword sub-pool), but its embedding is an EXACT match (cosine 1.0)
      # — the strongest possible absolute semantic signal, and no decoy comes close
      # (their absolute similarity is 0.0).
      curated =
        tenant.id
        |> curated_article(%{
          title: "Refund Policy Definitive Answer",
          body: "Our refund policy is fully documented here with complete refund guidance."
        })
        |> then(&set_embedding(tenant.id, &1, @direction_a))

      stub_embeddings_by_query(%{query => @direction_a})

      # Default page (limit 10, offset 0): the curated doc ranks 13th by the
      # keyword-heavy combined `:final_score` — but the resolver still finds and
      # scores it correctly, AND hoists it to the front of the returned page (it is
      # `List.first/1`, not merely present somewhere in the pool) so a caller trusting
      # `results[0]` as "the curated answer" is never handed a decoy instead.
      assert {:ok, %{results: page1, meta: meta1}} =
               Knowledge.hybrid_search(tenant.id, query,
                 keyword_weight: 0.9,
                 semantic_weight: 0.1
               )

      assert meta1.provenance == :curated
      assert meta1.confidence == 1.0
      assert meta1.curated_article_id == curated.id
      assert %{id: curated_id} = List.first(page1)
      assert curated_id == curated.id

      # A deeper page (offset 10) shifts to the tail of the reordered pool — the
      # curated winner (now pinned at position 0) does NOT reappear on a later page,
      # but the DECISION (provenance/confidence/curated_article_id) is identical: the
      # offset shifted only which page came back, never which candidates the resolver
      # reasoned over nor which one won.
      assert {:ok, %{results: page2, meta: meta2}} =
               Knowledge.hybrid_search(tenant.id, query,
                 keyword_weight: 0.9,
                 semantic_weight: 0.1,
                 offset: 10
               )

      refute Enum.any?(page2, &(&1.id == curated.id))
      assert meta2.provenance == :curated
      assert meta2.confidence == 1.0
      assert meta2.curated_article_id == curated.id
    end
  end

  # --- TC-31.2.2: curated and retrieved responses share the same shape ---

  describe "hybrid_search/3 - shape parity between :curated and :retrieved (TC-31.2.2)" do
    test "curated and retrieved responses have identical result/meta key sets" do
      curated_tenant = fixture(:tenant)
      Knowledge.reset_circuit_breaker(curated_tenant.id)

      curated = curated_article(curated_tenant.id, %{title: "Deploy Guide Curated"})
      set_embedding(curated_tenant.id, curated, @direction_a)

      stub_embeddings_by_query(%{"deploy guide" => @direction_a})

      assert {:ok, %{results: [curated_result | _], meta: curated_meta}} =
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

      assert {:ok, %{results: [retrieved_result | _], meta: retrieved_meta}} =
               Knowledge.hybrid_search(retrieved_tenant.id, "niche topic")

      assert retrieved_meta.provenance == :retrieved

      assert Enum.sort(Map.keys(curated_meta)) == Enum.sort(Map.keys(retrieved_meta))

      # The CORE identity/ranking fields are present on every result regardless of
      # provenance. The OPTIONAL raw score fields (`:relevance_score`/`:snippet` from
      # the keyword sub-pool, `:similarity_score` from the semantic sub-pool) legitimately
      # vary per CANDIDATE based on which sub-pool(s) it individually matched — that is
      # inherent to `search_combined/3`'s per-candidate merge (a keyword-only match never
      # carries `:similarity_score`; a semantic-only match never carries
      # `:relevance_score`/`:snippet`) and orthogonal to provenance, so it is not part of
      # the shape-parity contract this test guards.
      core_fields = [
        :id,
        :tenant_id,
        :project_id,
        :title,
        :category,
        :status,
        :tags,
        :inserted_at,
        :updated_at,
        :final_score
      ]

      for field <- core_fields do
        assert Map.has_key?(curated_result, field)
        assert Map.has_key?(retrieved_result, field)
      end

      for key <- [:provenance, :confidence, :search_mode, :curated_article_id] do
        assert Map.has_key?(curated_meta, key)
        assert Map.has_key?(retrieved_meta, key)
      end

      # curated_article_id is the actionable pointer (finding: mislabeled-authoritative
      # decoy) — present with a real id when :curated won, nil on the :retrieved branch.
      assert curated_meta.curated_article_id == curated.id
      assert retrieved_meta.curated_article_id == nil
    end
  end

  # --- TC-31.2.3: long-tail query falls back to retrieval, flagged ---

  describe "hybrid_search/3 - long-tail query falls back to retrieval (TC-31.2.3)" do
    test "no curated content for the tenant -> :retrieved with search_mode in meta" do
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
      assert is_binary(meta.search_mode)
    end
  end

  # --- TC-31.2.4: threshold/margin resolution is a testable pure decision ---

  describe "resolve_provenance/4 - pure resolution rule (TC-31.2.4)" do
    test "above threshold and beats margin -> :curated" do
      assert Knowledge.resolve_provenance(0.9, 0.5, 0.75, 0.1) == :curated
    end

    test "above threshold but within margin -> :retrieved" do
      assert Knowledge.resolve_provenance(0.8, 0.75, 0.75, 0.1) == :retrieved
    end

    test "below threshold -> :retrieved (even with a huge margin over retrieval)" do
      assert Knowledge.resolve_provenance(0.6, 0.0, 0.75, 0.1) == :retrieved
    end

    test "no authoritative curated candidate (nil score) -> :retrieved" do
      assert Knowledge.resolve_provenance(nil, 0.9, 0.75, 0.1) == :retrieved
    end

    test "exact boundary: threshold and margin both met exactly -> :curated" do
      # 0.5, 0.75, 0.25 are exactly representable in binary floating point, so the
      # `>=` boundary checks are exact (no float-precision flake at the edge).
      assert Knowledge.resolve_provenance(0.75, 0.5, 0.5, 0.25) == :curated
    end
  end

  # --- TC-31.2.5: degraded embeddings: honest meta, no false curated ---

  describe "hybrid_search/3 - degraded embeddings: honest meta, no false curated (TC-31.2.5)" do
    test "a curated source that is still confidently keyword-matched wins :curated under keyword_only fallback" do
      tenant = fixture(:tenant)
      Knowledge.reset_circuit_breaker(tenant.id)

      curated =
        curated_article(tenant.id, %{
          title: "Refund Policy Guide",
          body: "Our refund policy allows returns within 30 days. Refund policy details follow."
        })

      Mox.stub(Loopctl.MockEmbeddingClient, :generate_embedding, fn _tenant_id, _text ->
        {:error, :service_unavailable}
      end)

      assert {:ok, %{results: results, meta: meta}} =
               Knowledge.hybrid_search(tenant.id, "refund policy")

      assert meta.fallback == true
      assert meta.search_mode == "keyword_only"
      assert meta.provenance == :curated
      assert Enum.any?(results, &(&1.id == curated.id))
    end

    # Regression (finding 2): the positive case above previously passed for ANY sole
    # keyword hit regardless of ts_rank strength (min-max normalization forced a lone
    # candidate to 1.0). This negative case proves the resolver actually discriminates
    # on keyword-match STRENGTH: a curated doc that only incidentally mentions the
    # query terms once, deep in an otherwise-unrelated document (a genuinely weak,
    # non-"confidently identifiable" raw ts_rank_cd), must fall to :retrieved even as
    # the sole curated (and sole matching) candidate.
    test "a weakly/incidentally keyword-matched curated source (low raw ts_rank) falls to :retrieved as the sole matching candidate" do
      tenant = fixture(:tenant)
      Knowledge.reset_circuit_breaker(tenant.id)

      weakly_matched =
        curated_article(tenant.id, %{
          title: "Unrelated Document Title",
          body:
            "This is a long document about many different topics. Somewhere deep in " <>
              "this text we mention the refund policy just once in passing, without " <>
              "further discussion. The rest of this document covers unrelated material " <>
              "about logistics, warehousing, inventory management, and other operational " <>
              "topics that have nothing to do with the query at hand."
        })

      Mox.stub(Loopctl.MockEmbeddingClient, :generate_embedding, fn _tenant_id, _text ->
        {:error, :service_unavailable}
      end)

      assert {:ok, %{results: results, meta: meta}} =
               Knowledge.hybrid_search(tenant.id, "refund policy")

      assert meta.fallback == true
      assert meta.search_mode == "keyword_only"
      assert meta.provenance == :retrieved
      assert Enum.any?(results, &(&1.id == weakly_matched.id))
    end

    test "a curated source NOT keyword-matched falls to :retrieved under keyword_only fallback (never a false curated)" do
      tenant = fixture(:tenant)
      Knowledge.reset_circuit_breaker(tenant.id)

      _curated =
        curated_article(tenant.id, %{
          title: "Refund Policy Guide",
          body: "Our refund policy allows returns within 30 days."
        })

      distractor =
        fixture(:article, %{
          tenant_id: tenant.id,
          title: "Database Migration Strategy",
          body: "How to plan a database migration strategy safely. Migration, migration.",
          status: :published
        })

      Mox.stub(Loopctl.MockEmbeddingClient, :generate_embedding, fn _tenant_id, _text ->
        {:error, :service_unavailable}
      end)

      assert {:ok, %{results: results, meta: meta}} =
               Knowledge.hybrid_search(tenant.id, "database migration strategy")

      assert meta.fallback == true
      assert meta.search_mode == "keyword_only"
      assert meta.provenance == :retrieved
      assert Enum.any?(results, &(&1.id == distractor.id))
    end

    test "no matching articles at all under keyword_only fallback -> honest empty, never a crash or false curated" do
      tenant = fixture(:tenant)
      Knowledge.reset_circuit_breaker(tenant.id)

      Mox.stub(Loopctl.MockEmbeddingClient, :generate_embedding, fn _tenant_id, _text ->
        {:error, :service_unavailable}
      end)

      assert {:ok, %{results: [], meta: meta}} =
               Knowledge.hybrid_search(tenant.id, "completely absent phrase xyz")

      assert meta.fallback == true
      assert meta.search_mode == "keyword_only"
      assert meta.provenance == :retrieved
      assert meta.confidence == 0.0
    end
  end

  # --- TC-31.2.6: hybrid_search is tenant-isolated ---

  describe "hybrid_search/3 - tenant isolation (TC-31.2.6)" do
    test "threads tenant_id into both retrieval and curated lookup; no cross-tenant leakage" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      Knowledge.reset_circuit_breaker(tenant_a.id)
      Knowledge.reset_circuit_breaker(tenant_b.id)

      curated_a =
        curated_article(tenant_a.id, %{
          title: "Tenant A Secret Policy",
          body: "Tenant A's secret refund handling policy. Refund, refund policy."
        })

      Mox.stub(Loopctl.MockEmbeddingClient, :generate_embedding, fn _tenant_id, _text ->
        {:ok, List.duplicate(0.1, 1536)}
      end)

      assert {:ok, %{results: results_b, meta: meta_b}} =
               Knowledge.hybrid_search(tenant_b.id, "tenant a secret refund handling policy")

      assert results_b == []
      refute Enum.any?(results_b, &(&1.id == curated_a.id))
      assert meta_b.provenance == :retrieved
    end
  end

  # --- AC-31.2.5: provenance outcome emitted into retrieval metrics ---

  describe "hybrid_search/3 - provenance metrics emission (AC-31.2.5)" do
    test "the provenance outcome is recorded on the ArticleAccessEvent metadata mode tag, without double-recording" do
      tenant = fixture(:tenant)
      {_raw, api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      Knowledge.reset_circuit_breaker(tenant.id)

      curated = curated_article(tenant.id, %{title: "Deploy Guide Curated"})
      set_embedding(tenant.id, curated, @direction_a)

      stub_embeddings_by_query(%{"deploy guide" => @direction_a})

      assert {:ok, %{meta: %{provenance: :curated}}} =
               Knowledge.hybrid_search(tenant.id, "deploy guide",
                 keyword_weight: 0,
                 semantic_weight: 1,
                 api_key_id: api_key.id
               )

      events =
        AdminRepo.all(
          from(e in ArticleAccessEvent,
            where: e.tenant_id == ^tenant.id and e.access_type == "search"
          )
        )

      assert events != []
      assert Enum.all?(events, &(&1.metadata["mode"] == "hybrid_curated"))

      # The inner search_combined/3 recording was suppressed (`_skip_record_access`),
      # so there is no separate "combined"-tagged event double-counting
      # RetrievalMetrics' `searched` aggregate.
      refute Enum.any?(events, &(&1.metadata["mode"] == "combined"))
    end

    test "a :retrieved outcome is tagged hybrid_retrieved" do
      tenant = fixture(:tenant)
      {_raw, api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      Knowledge.reset_circuit_breaker(tenant.id)

      fixture(:article, %{
        tenant_id: tenant.id,
        title: "Uncurated Guide",
        body: "An uncurated article about some general topic.",
        status: :published
      })

      assert {:ok, %{meta: %{provenance: :retrieved}}} =
               Knowledge.hybrid_search(tenant.id, "general topic", api_key_id: api_key.id)

      events =
        AdminRepo.all(
          from(e in ArticleAccessEvent,
            where: e.tenant_id == ^tenant.id and e.access_type == "search"
          )
        )

      assert events != []
      assert Enum.all?(events, &(&1.metadata["mode"] == "hybrid_retrieved"))
    end
  end

  # --- Regression (finding 6): the ArticleAccessEvent/RetrievalMetrics recording
  # structurally CANNOT represent a MISS (empty page — `article_id` is NOT NULL) or a
  # keyless call (no `api_key_id` to attribute a row to). The hybrid-provenance
  # telemetry event closes that observability gap by firing unconditionally.

  describe "hybrid_search/3 - provenance telemetry fires even for a MISS or a keyless call (finding 6 regression)" do
    defp attach_hybrid_provenance_handler(tenant_id) do
      test_pid = self()
      handler_id = "hybrid-prov-#{System.unique_integer([:positive])}"
      event = [:loopctl, :knowledge, :hybrid_provenance]

      :telemetry.attach(
        handler_id,
        event,
        fn ^event, measurements, metadata, _config ->
          if metadata.tenant_id == tenant_id do
            send(test_pid, {:hybrid_provenance, measurements, metadata})
          end
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)
    end

    test "a :retrieved MISS (empty results, no api_key_id) still emits the telemetry event" do
      tenant = fixture(:tenant)
      Knowledge.reset_circuit_breaker(tenant.id)
      attach_hybrid_provenance_handler(tenant.id)

      assert {:ok, %{results: [], meta: %{provenance: :retrieved}}} =
               Knowledge.hybrid_search(tenant.id, "completely absent phrase xyz")

      assert_receive {:hybrid_provenance, %{count: 1}, metadata}
      assert metadata.provenance == "retrieved"
      assert metadata.hit == false

      # No ArticleAccessEvent could possibly have been recorded for this MISS
      # (article_id is NOT NULL) — the telemetry event is the ONLY observable trace.
      assert AdminRepo.aggregate(
               from(e in ArticleAccessEvent, where: e.tenant_id == ^tenant.id),
               :count,
               :id
             ) == 0
    end

    test "a hit with no :api_key_id (keyless call) still emits the telemetry event" do
      tenant = fixture(:tenant)
      Knowledge.reset_circuit_breaker(tenant.id)
      attach_hybrid_provenance_handler(tenant.id)

      fixture(:article, %{
        tenant_id: tenant.id,
        title: "Keyless Caller Guide",
        body: "An article findable by a caller with no api_key_id attribution.",
        status: :published
      })

      assert {:ok, %{results: results, meta: %{provenance: :retrieved}}} =
               Knowledge.hybrid_search(tenant.id, "keyless caller guide")

      assert results != []

      assert_receive {:hybrid_provenance, %{count: 1}, metadata}
      assert metadata.provenance == "retrieved"
      assert metadata.hit == true

      # No ArticleAccessEvent could possibly have been recorded (no api_key_id to
      # attribute to) — the telemetry event is the ONLY observable trace.
      assert AdminRepo.aggregate(
               from(e in ArticleAccessEvent, where: e.tenant_id == ^tenant.id),
               :count,
               :id
             ) == 0
    end

    test "a :curated hit DOES double-record: the DB event (api_key_id present) AND the telemetry event" do
      tenant = fixture(:tenant)
      {_raw, api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      Knowledge.reset_circuit_breaker(tenant.id)
      attach_hybrid_provenance_handler(tenant.id)

      curated = curated_article(tenant.id, %{title: "Telemetry Deploy Guide"})
      set_embedding(tenant.id, curated, @direction_a)
      stub_embeddings_by_query(%{"telemetry deploy guide" => @direction_a})

      assert {:ok, %{meta: %{provenance: :curated}}} =
               Knowledge.hybrid_search(tenant.id, "telemetry deploy guide",
                 keyword_weight: 0,
                 semantic_weight: 1,
                 api_key_id: api_key.id
               )

      assert_receive {:hybrid_provenance, %{count: 1}, metadata}
      assert metadata.provenance == "curated"
      assert metadata.hit == true

      assert AdminRepo.aggregate(
               from(e in ArticleAccessEvent, where: e.tenant_id == ^tenant.id),
               :count,
               :id
             ) == 1
    end
  end
end
