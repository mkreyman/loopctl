defmodule LoopctlWeb.RecallControllerTest do
  @moduledoc """
  #411 Gap 2 (PR B): the merged recall endpoint `POST /api/v1/recall`
  (`MemoryController.context/2`). Covers the 200 merged shape, the reused 422 envelopes
  (invalid_query / invalid_project_id), and the subject-unresolvable guard.
  """
  use LoopctlWeb.ConnCase, async: true

  import Ecto.Query

  setup :verify_on_exit!

  alias Loopctl.Auth.ApiKey
  alias Loopctl.Knowledge
  alias Loopctl.Knowledge.Analytics
  alias LoopctlWeb.MemoryController

  defp auth(conn, raw_key), do: put_req_header(conn, "authorization", "Bearer #{raw_key}")

  defp base_conn,
    do: put_req_header(build_conn(), "x-loopctl-last-known-sth", "0:AAAAAAAAAAAAAAAAAAAAAA")

  defp agent_key(tenant_id) do
    agent = fixture(:agent, %{tenant_id: tenant_id})
    {raw, key} = fixture(:api_key, %{tenant_id: tenant_id, role: :agent, agent_id: agent.id})
    {raw, key, agent}
  end

  defp published_article(tenant_id, title) do
    art =
      fixture(:article, %{
        tenant_id: tenant_id,
        status: :published,
        title: title,
        body: "reshipment policy for #{title}"
      })

    {:ok, updated} = Knowledge.update_embedding(tenant_id, art.id, List.duplicate(0.1, 1536))
    updated
  end

  describe "POST /api/v1/recall (merged memory ∪ knowledge)" do
    test "returns the merged shape with per-source envelopes and meta", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw, _key, _agent} = agent_key(tenant.id)
      Knowledge.reset_circuit_breaker(tenant.id)

      # A long-term memory (embedded inline) + a knowledge article.
      conn
      |> auth(raw)
      |> post(~p"/api/v1/memory", %{"tier" => "long_term", "text" => "prefers reshipments"})
      |> json_response(201)

      article = published_article(tenant.id, "reshipment guide")

      body =
        base_conn()
        |> auth(raw)
        |> post(~p"/api/v1/recall", %{"query" => "reshipments"})
        |> json_response(200)

      assert %{"data" => data, "memory" => memory, "knowledge" => knowledge, "meta" => meta} =
               body

      # Merged data is tagged per-source.
      sources = data |> Enum.map(& &1["source"]) |> Enum.uniq() |> Enum.sort()
      assert sources == ["knowledge", "memory"]

      # Sorted by score DESC (nulls ranked as 0.0 by the context; here all are numbers).
      scores = Enum.map(data, & &1["score"])
      assert scores == Enum.sort(scores, :desc)

      # Per-source envelopes present and shaped.
      assert %{"data" => mem_data, "meta" => mem_meta} = memory
      assert Enum.any?(mem_data, &(&1["memory"]["text"] == "prefers reshipments"))

      # BOTH halves disclose the vector read's iterative-scan state, under the SAME field
      # name and value vocabulary (#631 for knowledge, #634 for memory) — an agent reading
      # this one envelope must not have to learn two. Each half resolves the backend
      # capability independently, so they are asserted independently against the valid
      # set rather than against `applied`: iterative scan is pinned ON in `config/test.exs`
      # but the live probe fails closed to `unavailable` on a pool-checkout timeout, and an
      # async file cannot prime the VM-global verdict. The exact states live in the sync
      # `Loopctl.HeavyReadHnswEfSearchTest`.
      assert %{"data" => know_data, "meta" => know_meta} = knowledge
      assert mem_meta["ann_iterative_scan"] in ["applied", "unavailable"]
      assert know_meta["ann_iterative_scan"] in ["applied", "unavailable"]
      assert Enum.any?(know_data, &(&1["id"] == article.id))

      assert meta["query"] == "reshipments"
      assert meta["degraded"] == false
      assert meta["memory_count"] >= 1
      assert meta["knowledge_count"] >= 1
      assert meta["total_count"] == length(data)
      # The merged ordering is a documented cross-source heuristic, surfaced so callers
      # don't read it as calibrated relevance.
      assert meta["results_ranking"] == "heuristic_cross_source"

      # Knowledge items are the whitelisted combined-search SUMMARY — never the raw
      # result map's internal scoring fields, status, tenant_id, project_id, timestamps.
      know_item = Enum.find(know_data, &(&1["id"] == article.id))

      # `snippet_source` rides along deliberately: /recall is what the injected recall hook
      # renders, and a `ts_headline` highlight (carrying **term** markers, able to open
      # mid-sentence) reads very differently from a lead extract of the article's own
      # opening prose. The hook cannot render them appropriately without being told which
      # it has.
      assert Map.keys(know_item)
             |> Enum.sort()
             |> Enum.all?(&(&1 in ~w(id title category tags score snippet snippet_source)))

      refute Map.has_key?(know_item, "tenant_id")
      refute Map.has_key?(know_item, "status")
      refute Map.has_key?(know_item, "final_score")
      refute Map.has_key?(know_item, "inserted_at")

      merged_know = Enum.find(data, &(&1["source"] == "knowledge"))["article"]
      refute Map.has_key?(merged_know, "tenant_id")
      refute Map.has_key?(merged_know, "status")
    end

    test "a missing or blank/whitespace-only query is rejected with a 422 invalid_query" do
      tenant = fixture(:tenant)
      {raw, _key, _agent} = agent_key(tenant.id)

      for q <- [nil, "", "   ", "\t\n"] do
        params = if is_nil(q), do: %{}, else: %{"query" => q}

        body =
          base_conn()
          |> auth(raw)
          |> post(~p"/api/v1/recall", params)
          |> json_response(422)

        assert body["error"]["code"] == "invalid_query"
        assert body["error"]["status"] == 422
      end
    end

    test "an over-length (>500 char) query is rejected up front with a 422 query_too_long" do
      tenant = fixture(:tenant)
      {raw, _key, _agent} = agent_key(tenant.id)

      # 501 chars: rejected at the boundary BEFORE any embedding is generated, so the
      # knowledge half never half-degrades to an empty, spuriously-`degraded` 200.
      body =
        base_conn()
        |> auth(raw)
        |> post(~p"/api/v1/recall", %{"query" => String.duplicate("a", 501)})
        |> json_response(422)

      assert body["error"]["code"] == "query_too_long"
      assert body["error"]["status"] == 422
    end

    test "a query of exactly 500 chars is accepted (boundary, returns 200)" do
      tenant = fixture(:tenant)
      {raw, _key, _agent} = agent_key(tenant.id)
      Knowledge.reset_circuit_breaker(tenant.id)

      body =
        base_conn()
        |> auth(raw)
        |> post(~p"/api/v1/recall", %{"query" => String.duplicate("a", 500)})
        |> json_response(200)

      assert %{"meta" => _meta} = body
    end

    test "the knowledge envelope meta is the whitelisted search shape (no raw error atom)" do
      tenant = fixture(:tenant)
      {raw, _key, _agent} = agent_key(tenant.id)
      Knowledge.reset_circuit_breaker(tenant.id)
      _ = published_article(tenant.id, "reshipment guide")

      body =
        base_conn()
        |> auth(raw)
        |> post(~p"/api/v1/recall", %{"query" => "reshipments"})
        |> json_response(200)

      know_meta = body["knowledge"]["meta"]

      # Projected through KnowledgeSearchJSON.render_meta: the canonical counters are
      # present and the merged-recall `degraded` flag is re-attached...
      assert Map.has_key?(know_meta, "total_count")
      assert Map.has_key?(know_meta, "limit")
      assert Map.has_key?(know_meta, "offset")
      assert know_meta["degraded"] == false
      # ...and the raw internal reason atom is NEVER passed through (unlike the old raw
      # passthrough), matching what /knowledge/search would serialize.
      refute Map.has_key?(know_meta, "error")

      # The merged meta names why on degradation; healthy => null.
      assert Map.has_key?(body["meta"], "degraded_reason")
      assert body["meta"]["degraded_reason"] == nil
    end

    test "a non-string query is rejected with a deterministic 422 invalid_query" do
      tenant = fixture(:tenant)
      {raw, _key, _agent} = agent_key(tenant.id)

      body =
        base_conn()
        |> auth(raw)
        |> post(~p"/api/v1/recall", %{"query" => %{"nested" => "object"}})
        |> json_response(422)

      assert body["error"]["code"] == "invalid_query"
      assert body["error"]["status"] == 422
    end

    test "a malformed project_id is rejected with a deterministic 422 invalid_project_id" do
      tenant = fixture(:tenant)
      {raw, _key, _agent} = agent_key(tenant.id)

      body =
        base_conn()
        |> auth(raw)
        |> post(~p"/api/v1/recall", %{"query" => "reshipments", "project_id" => "not-a-uuid"})
        |> json_response(422)

      assert body["error"]["code"] == "invalid_project_id"
      assert body["error"]["status"] == 422
    end

    test "every merged item carries the selection ledger and meta carries the accounting" do
      tenant = fixture(:tenant)
      {raw, _key, _agent} = agent_key(tenant.id)
      Knowledge.reset_circuit_breaker(tenant.id)

      base_conn()
      |> auth(raw)
      |> post(~p"/api/v1/memory", %{"tier" => "long_term", "text" => "prefers reshipments"})
      |> json_response(201)

      _article = published_article(tenant.id, "reshipment guide")

      body =
        base_conn()
        |> auth(raw)
        |> post(~p"/api/v1/recall", %{"query" => "reshipments"})
        |> json_response(200)

      %{"data" => data, "meta" => meta} = body
      assert data != [], "the ledger assertions below are vacuous on an empty merge"

      # `rank` is the position in THIS list, so it is 1..n with no gaps regardless of what
      # each half ranked internally.
      assert Enum.map(data, & &1["rank"]) == Enum.to_list(1..length(data))

      valid_reasons =
        ~w(keyword semantic keyword+semantic keyword_fallback unscored ilike_fallback)

      for item <- data do
        assert item["selection_reason"] in valid_reasons
        assert is_integer(item["tokens_estimate"]) and item["tokens_estimate"] >= 0
      end

      # A memory row's reason comes from the ENVELOPE (which path ran), never from a
      # per-row nil score, which a legitimately-zero similarity would also produce.
      memory_item = Enum.find(data, &(&1["source"] == "memory"))
      assert memory_item["selection_reason"] in ~w(semantic ilike_fallback)

      assert meta["recall_id"] =~
               ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/

      assert meta["selected_count"] == length(data)
      assert meta["candidates_considered"]["total"] >= meta["selected_count"]

      assert meta["candidates_considered"]["memory"] +
               meta["candidates_considered"]["knowledge"] ==
               meta["candidates_considered"]["total"]

      assert meta["tokens_selected"] == Enum.sum(Enum.map(data, & &1["tokens_estimate"]))
      assert meta["tokens_candidates"] >= meta["tokens_selected"]

      assert meta["tokens_saved_vs_candidates"] ==
               meta["tokens_candidates"] - meta["tokens_selected"]
    end

    test "an unchanged corpus renders BYTE-IDENTICALLY between two recalls" do
      # The merged order is a total one (score DESC, then source, then id), so a client's
      # prompt cache survives a repeated turn. Score alone left cross-source ties to the
      # order two lists happened to be concatenated in. `recall_id` is per-call by design,
      # so it is excluded from the comparison — everything else must match to the byte.
      tenant = fixture(:tenant)
      {raw, _key, _agent} = agent_key(tenant.id)
      Knowledge.reset_circuit_breaker(tenant.id)

      base_conn()
      |> auth(raw)
      |> post(~p"/api/v1/memory", %{"tier" => "long_term", "text" => "prefers reshipments"})
      |> json_response(201)

      for title <- ["reshipment guide", "reshipment policy", "reshipment ledger"] do
        published_article(tenant.id, title)
      end

      render = fn ->
        base_conn()
        |> auth(raw)
        |> post(~p"/api/v1/recall", %{"query" => "reshipments"})
        |> json_response(200)
        |> Map.get("data")
        |> Jason.encode!()
      end

      first = render.()
      assert first != "[]", "an empty merge would make this determinism check vacuous"
      assert first == render.()
    end

    test "TIED rows are broken deterministically by id, not by arrival order" do
      # The byte-identity test above cannot see a MISSING tie-break while every score
      # differs, and a cross-source tie is hard to arrange on purpose. The memory ILIKE
      # fallback makes one for free: every row on that path has a null score, which the
      # merge ranks as 0.0, so all three tie and the ordering falls through to the
      # tie-break.
      #
      # The arrival order is PINNED rather than left to chance. `recall_fallback/6` orders
      # `[desc: inserted_at, desc: id]`, so flattening the three timestamps to one instant
      # makes recall hand the merge exactly `id DESC` — the reverse of what the tie-break
      # must produce. Without that, arrival order is by insertion time and lands in id-
      # ascending order 1 run in 6 by luck, which is a guard that reports "fine" on a
      # sixth of the regressions it exists to catch (verified by mutation: with the
      # tie-break removed this test failed on 4 fixed seeds and passed on one random one).
      tenant = fixture(:tenant)
      {raw, _key, agent} = agent_key(tenant.id)

      memories =
        for text <- ["reshipments alpha", "reshipments beta", "reshipments gamma"] do
          fixture(:memory, %{
            tenant_id: tenant.id,
            subject_id: to_string(agent.id),
            text: text
          })
        end

      pinned = ~N[2026-01-01 00:00:00]

      {3, _} =
        from(m in Loopctl.Memory.Memory, where: m.id in ^Enum.map(memories, & &1.id))
        |> Loopctl.AdminRepo.update_all(set: [inserted_at: pinned])

      Mox.stub(Loopctl.MockEmbeddingClient, :generate_embedding, fn _tenant_id, _text ->
        {:error, :no_api_key}
      end)

      data =
        base_conn()
        |> auth(raw)
        |> post(~p"/api/v1/recall", %{"query" => "reshipments"})
        |> json_response(200)
        |> Map.get("data")

      memory_items = Enum.filter(data, &(&1["source"] == "memory"))
      assert length(memory_items) == 3, "the tie-break check is vacuous with fewer than 2 rows"

      ids = Enum.map(memory_items, & &1["memory"]["id"])

      refute ids == Enum.sort(ids, :desc),
             "recall did not hand the merge a descending order, so this check proves nothing"

      assert ids == Enum.sort(ids), "tied rows were not ordered by id"

      # And the reason is read from the ENVELOPE (which path ran), not from the nil score.
      assert Enum.all?(memory_items, &(&1["selection_reason"] == "ilike_fallback"))

      assert Enum.all?(memory_items, &is_nil(&1["score"])),
             "the per-source envelope must keep the honest nil; only the ORDER treats it as 0.0"
    end

    test "meta.recall_id IS the search_id on the surfacing rows (one id, not two)" do
      # The whole point of publishing it: `POST /recall/:recall_id/referenced` checks what
      # a recall surfaced by looking up rows carrying this id. A second, unrelated id would
      # make that check impossible to satisfy.
      tenant = fixture(:tenant)
      {raw, key, _agent} = agent_key(tenant.id)
      Knowledge.reset_circuit_breaker(tenant.id)
      article = published_article(tenant.id, "reshipment guide")

      body =
        base_conn()
        |> auth(raw)
        |> post(~p"/api/v1/recall", %{"query" => "reshipments"})
        |> json_response(200)

      recall_id = body["meta"]["recall_id"]
      assert is_binary(recall_id)

      # Recording is async off the request path; wait for the surfacing rows to land.
      surfaced =
        Enum.reduce_while(1..50, [], fn _i, _acc ->
          ids = Analytics.surfaced_article_ids(tenant.id, recall_id)

          if article.id in ids do
            {:halt, ids}
          else
            Process.sleep(20)
            {:cont, ids}
          end
        end)

      assert article.id in surfaced,
             "the recall published a recall_id that names no surfacing rows"

      assert key.id
    end

    test "an identity-less key is refused with a deterministic 422 (subject_id_unresolvable)" do
      tenant = fixture(:tenant)

      conn =
        build_conn()
        |> Plug.Conn.assign(:current_api_key, %ApiKey{
          id: nil,
          tenant_id: tenant.id,
          role: :agent,
          agent_id: nil
        })

      result = MemoryController.context(conn, %{"query" => "reshipments"})
      assert json_response(result, 422)["error"]["code"] == "subject_id_unresolvable"
    end
  end
end
