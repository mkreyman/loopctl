defmodule LoopctlWeb.KnowledgeSuggestLinksControllerTest do
  use LoopctlWeb.ConnCase, async: true

  alias Ecto.Adapters.SQL
  alias Loopctl.AdminRepo
  alias Loopctl.HeavyRead.TenantGate
  alias Loopctl.Knowledge
  alias Loopctl.Knowledge.ArticleLink

  import Ecto.Query
  import ExUnit.CaptureLog

  setup :verify_on_exit!

  defp auth_conn(conn, raw_key), do: put_req_header(conn, "authorization", "Bearer #{raw_key}")

  defp setup_tenant_key do
    tenant = fixture(:tenant)
    {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
    {tenant, raw_key}
  end

  # 1536-dim vector from a sparse prefix (rest zero-filled). Cosine is magnitude-
  # independent: e([1.0]) vs e([1.0]) = 1; vs e([1.0, 1.0]) = 1/√2 ≈ 0.707; vs
  # e([0.0, 1.0]) = 0.
  defp e(prefix), do: prefix ++ List.duplicate(0.0, 1536 - length(prefix))

  defp embedded(tenant_id, title, vector, status \\ :published) do
    a = fixture(:article, %{tenant_id: tenant_id, title: title, status: status})
    {:ok, _} = Knowledge.update_embedding(tenant_id, a.id, e(vector))
    a
  end

  defp suggest(conn, key, id, query \\ %{}) do
    conn
    |> auth_conn(key)
    |> get(~p"/api/v1/knowledge/articles/#{id}/suggested_links?#{query}")
    |> json_response(200)
  end

  defp ids(body), do: Enum.map(body["data"], & &1["id"])

  describe "suggestion query shape (#168 + #172 RED→GREEN structural guard)" do
    # Neither production 500 reproduces in the test DB: #168 (re-interpolating a stored
    # %Pgvector{}) encodes fine locally, and #172 (a full-corpus scan + sort) only times
    # out at prod scale (~76k published articles) — a handful of test rows never exhibit
    # it. This guard asserts the QUERY SHAPE instead, catching BOTH regressions:
    #
    #   * #172: the target embedding is a BOUND list parameter and the `articles` table
    #     appears EXACTLY ONCE — there is no self-join to read the target vector as a
    #     column. The bound-`^param` left-vs-const form is what the HNSW index
    #     (`articles_embedding_hnsw_idx`, vector_cosine_ops) accelerates; the old
    #     self-join forced a per-row cosine + full sort over the whole corpus.
    #   * #168: that bound param is a plain LIST of floats, NEVER the stored `%Pgvector{}`
    #     struct (binding the struct was the original 500).
    #
    # A literal 76k-row seed is infeasible in an async unit test, so this fast SQL-shape
    # check is the first guard; the EXPLAIN test below is the stronger one — it asserts the
    # planner can actually use the HNSW index (the real "does not full-scan" property).
    test "binds the target as a list param (HNSW-indexable), with no full-corpus self-join" do
      {tenant, _key} = setup_tenant_key()
      target = embedded(tenant.id, "T", [1.0, 0.0])

      query =
        Knowledge.suggestion_candidates_query(tenant.id, target.id, e([1.0, 0.0]), 0.5, 5, nil)

      {sql, params} = SQL.to_sql(:all, AdminRepo, query)

      # #172: the target vector is a BOUND parameter (a list), enabling the indexable
      # `ORDER BY embedding <=> $const LIMIT k` form.
      assert Enum.any?(params, &is_list/1)

      # #168: that param is a plain list, NEVER the stored %Pgvector{} struct.
      refute Enum.any?(params, &match?(%Pgvector{}, &1))

      # #172: exactly one `articles` table reference — no self-join driving a
      # full-corpus scan. (The only other table is the `article_links` exclusion join.)
      assert sql =~ "<=>"
      assert length(Regex.scan(~r/"articles"/, sql)) == 1
      assert sql =~ ~r/order by .*<=>/i
    end

    # The SQL-shape check above guards the self-join specifically; this guards the broader
    # #172 regression CLASS — "the corpus is reached through the HNSW index, never a full
    # Seq Scan + Sort" — which a shape regex can't see. This is THE bug that shipped twice
    # (#170, then the first #172 attempt): both passed every behavioral test because at test
    # scale the planner seq-scans 6 rows happily; only at prod scale (~76k rows) does the
    # Seq Scan + Sort blow the statement timeout. Verified against the real prod corpus,
    # the fix is a subquery: the inner ANN (`ORDER BY embedding <=> $const LIMIT pool`) uses
    # `articles_embedding_hnsw_idx`; the anti-join + threshold live in the OUTER query (each
    # would defeat the index if pushed inside). With seq-scan disabled the planner must
    # reach `articles` via that index — so the plan names the HNSW index and contains NO
    # `Seq Scan on articles`. (An outer Sort over the small candidate pool is expected and
    # fine — it is NOT a full-corpus sort.) An index-defeating rewrite (anti-join/threshold
    # back inside, a self-join column operand, a dropped index) reintroduces `Seq Scan on
    # articles`, failing this. Deterministic at any row count.
    test "EXPLAIN: corpus reached via the HNSW index, never a full Seq Scan on articles" do
      {tenant, _key} = setup_tenant_key()
      target = embedded(tenant.id, "Target", [1.0, 0.0])
      for i <- 1..5, do: embedded(tenant.id, "C#{i}", [1.0, 0.0])

      query =
        Knowledge.suggestion_candidates_query(tenant.id, target.id, e([1.0, 0.0]), 0.5, 5, nil)

      {sql, params} = SQL.to_sql(:all, AdminRepo, query)

      {:ok, plan} =
        AdminRepo.transaction(fn ->
          # Disable seq-scan AND sort so the inner ANN must reach `articles` through the
          # HNSW index — reflecting whether it CAN, not whether HNSW wins the cost model at
          # 6 rows. (The outer sort over the small candidate pool is unaffected/expected.)
          AdminRepo.query!("SET LOCAL enable_seqscan = off")
          AdminRepo.query!("SET LOCAL enable_sort = off")
          %{rows: rows} = AdminRepo.query!("EXPLAIN " <> sql, params)
          Enum.map_join(rows, "\n", &Enum.join(&1, " "))
        end)

      # The corpus is read through the HNSW index as an INDEX SCAN for the ordering
      # (not merely the index name appearing somewhere). US-27.14 reconciled the
      # index name to the single canonical `articles_embedding_hnsw_idx` in every env
      # (test + prod), so this assertion is now exact rather than name-agnostic.
      assert plan =~ ~r/Index Scan using articles_embedding_hnsw_idx/
      # ...never a full-corpus Seq Scan (the #170/#172 production 500).
      refute plan =~ ~r/Seq Scan on articles\b/i
    end
  end

  describe "GET /api/v1/knowledge/articles/:id/suggested_links (#150)" do
    # #168/#172 regression: the endpoint 500'd in production. #168 was re-interpolating
    # the stored `%Pgvector{}` as a `^param::vector`; #172 was the self-join that read the
    # target vector as a column, forcing a full-corpus scan. The query now binds the target
    # as a plain list param (HNSW-indexable `ORDER BY embedding <=> $const LIMIT k`). This
    # guards the end-to-end HTTP path (controller → query → JSON) returns 200 with the
    # documented candidate shape.
    test "returns 200 with ranked candidate shape (no 500) — #168", %{conn: conn} do
      {tenant, key} = setup_tenant_key()
      target = embedded(tenant.id, "Target168", [1.0, 0.0])
      c1 = embedded(tenant.id, "Cand1", [1.0, 0.0])
      c2 = embedded(tenant.id, "Cand2", [0.9, 0.1])

      conn =
        conn |> auth_conn(key) |> get(~p"/api/v1/knowledge/articles/#{target.id}/suggested_links")

      # The key assertion: a clean 200, never a 500.
      body = json_response(conn, 200)
      returned = ids(body)
      assert c1.id in returned
      assert c2.id in returned
      refute target.id in returned

      for cand <- body["data"] do
        assert is_binary(cand["id"])
        assert is_binary(cand["title"])
        assert cand["category"]
        assert is_number(cand["similarity_score"])
        assert cand["similarity_score"] >= 0.5
      end
    end

    test "returns candidates ranked by similarity, highest first, excluding below-threshold",
         %{conn: conn} do
      {tenant, key} = setup_tenant_key()
      target = embedded(tenant.id, "Target", [1.0])
      identical = embedded(tenant.id, "Identical", [1.0])
      medium = embedded(tenant.id, "Medium", [1.0, 1.0])
      _orthogonal = embedded(tenant.id, "Orthogonal", [0.0, 1.0])

      body = suggest(conn, key, target.id)

      # orthogonal (cosine 0) is below the 0.5 default threshold → excluded.
      assert ids(body) == [identical.id, medium.id]
      # similarity_score present and descending; carries id/title/category.
      [first, second] = body["data"]
      assert first["similarity_score"] >= second["similarity_score"]
      assert first["title"] == "Identical"
      assert first["category"]
    end

    test "excludes the article itself and any already-linked article (either direction)",
         %{conn: conn} do
      {tenant, key} = setup_tenant_key()
      target = embedded(tenant.id, "Target", [1.0])
      linked = embedded(tenant.id, "Linked", [1.0])
      free = embedded(tenant.id, "Free", [1.0])

      # Existing link target→linked (any type) must exclude `linked`.
      fixture(:article_link, %{
        tenant_id: tenant.id,
        source_article_id: target.id,
        target_article_id: linked.id,
        relationship_type: :derived_from
      })

      body = suggest(conn, key, target.id)

      assert target.id not in ids(body)
      assert linked.id not in ids(body)
      assert free.id in ids(body)
    end

    # Exclusion-under-limit contract: every already-linked near-neighbor is removed and
    # none leaks through, and the result is filled from the remaining unlinked candidates
    # rather than truncated by the anti-join. (Exact at test scale; the prod recall ceiling
    # is documented on `suggest_links/3` — approximate-NN bounded by HNSW `ef_search`.)
    test "excludes all already-linked near-neighbors and fills from the unlinked remainder",
         %{conn: conn} do
      {tenant, key} = setup_tenant_key()
      target = embedded(tenant.id, "Target", [1.0])
      # Six equally-similar candidates; pre-link four so only two remain unlinked.
      linked = for i <- 1..4, do: embedded(tenant.id, "Linked#{i}", [1.0])
      free1 = embedded(tenant.id, "Free1", [1.0])
      free2 = embedded(tenant.id, "Free2", [1.0])

      for l <- linked do
        fixture(:article_link, %{
          tenant_id: tenant.id,
          source_article_id: target.id,
          target_article_id: l.id,
          relationship_type: :relates_to
        })
      end

      returned = ids(suggest(conn, key, target.id, %{limit: 2}))

      # Exactly the two unlinked candidates — none of the four linked ones leak through,
      # and the result is not starved below the requested limit.
      assert Enum.sort(returned) == Enum.sort([free1.id, free2.id])
      for l <- linked, do: assert(l.id not in returned)
    end

    test "is read-only — creates no links", %{conn: conn} do
      {tenant, key} = setup_tenant_key()
      target = embedded(tenant.id, "Target", [1.0])
      _candidate = embedded(tenant.id, "Candidate", [1.0])

      before =
        AdminRepo.aggregate(from(l in ArticleLink, where: l.tenant_id == ^tenant.id), :count, :id)

      _ = suggest(conn, key, target.id)

      after_count =
        AdminRepo.aggregate(from(l in ArticleLink, where: l.tenant_id == ^tenant.id), :count, :id)

      assert before == 0
      assert after_count == 0
    end

    # US-27.6b AC-27.6b.6: the response carries a `meta` recall-completeness block so
    # an agent can tell an INCOMPLETE result (densely-linked hub) from an empty one.
    test "response meta carries recall_truncated=true for a densely-linked hub", %{conn: conn} do
      {tenant, key} = setup_tenant_key()
      hub = embedded(tenant.id, "Hub", [1.0, 0.0])
      # Fill the test 6-row pool with 6 near neighbors, all already-linked → the
      # anti-join exhausts the full pool below the default limit of 5.
      neighbors = for i <- 1..6, do: embedded(tenant.id, "N#{i}", [1.0, 0.0])

      for n <- neighbors do
        fixture(:article_link, %{
          tenant_id: tenant.id,
          source_article_id: hub.id,
          target_article_id: n.id,
          relationship_type: :relates_to
        })
      end

      body = suggest(conn, key, hub.id)

      assert length(body["data"]) < 5
      assert body["meta"]["recall_truncated"] == true
      assert body["meta"]["pool_exhausted"] == true
      assert body["meta"]["requested"] == 5
      assert body["meta"]["returned"] == length(body["data"])
    end

    test "response meta carries recall_truncated=false for a full result", %{conn: conn} do
      {tenant, key} = setup_tenant_key()
      target = embedded(tenant.id, "Target", [1.0, 0.0])
      for i <- 1..6, do: embedded(tenant.id, "Free#{i}", [1.0, 0.0])

      body = suggest(conn, key, target.id, %{limit: 5})

      assert length(body["data"]) == 5
      assert body["meta"]["recall_truncated"] == false
      assert body["meta"]["pool_exhausted"] == false
      assert body["meta"]["returned"] == 5
    end

    test "response meta is recall_truncated=false for a genuinely-empty result (not under-fill)",
         %{conn: conn} do
      {tenant, key} = setup_tenant_key()
      # No embedding → empty result; this is NOT a recall incident.
      target =
        fixture(:article, %{tenant_id: tenant.id, title: "No Embedding", status: :published})

      body = suggest(conn, key, target.id)

      assert body["data"] == []
      assert body["meta"]["recall_truncated"] == false
      assert body["meta"]["pool_exhausted"] == false
    end

    test "honors limit and threshold", %{conn: conn} do
      {tenant, key} = setup_tenant_key()
      target = embedded(tenant.id, "Target", [1.0])
      embedded(tenant.id, "C1", [1.0])
      embedded(tenant.id, "C2", [1.0])
      embedded(tenant.id, "C3", [1.0])

      assert length(ids(suggest(conn, key, target.id, %{limit: 1}))) == 1

      # threshold 0.99 still keeps the identical (cosine 1) candidates.
      assert length(ids(suggest(conn, key, target.id, %{threshold: "0.99"}))) == 3
    end

    test "excludes draft candidates (published-only)", %{conn: conn} do
      {tenant, key} = setup_tenant_key()
      target = embedded(tenant.id, "Target", [1.0])
      _draft = embedded(tenant.id, "Draft Candidate", [1.0], :draft)

      assert ids(suggest(conn, key, target.id)) == []
    end

    test "a published article with no embedding returns an empty list", %{conn: conn} do
      {tenant, key} = setup_tenant_key()

      target =
        fixture(:article, %{tenant_id: tenant.id, title: "No Embedding", status: :published})

      assert ids(suggest(conn, key, target.id)) == []
    end

    test "nonexistent or draft target returns 404", %{conn: conn} do
      {tenant, key} = setup_tenant_key()

      conn
      |> auth_conn(key)
      |> get(~p"/api/v1/knowledge/articles/#{Ecto.UUID.generate()}/suggested_links")
      |> json_response(404)

      draft = fixture(:article, %{tenant_id: tenant.id, title: "Draft", status: :draft})

      build_conn()
      |> auth_conn(key)
      |> get(~p"/api/v1/knowledge/articles/#{draft.id}/suggested_links")
      |> json_response(404)
    end

    test "invalid threshold returns 400", %{conn: conn} do
      {tenant, key} = setup_tenant_key()
      target = embedded(tenant.id, "Target", [1.0])

      resp =
        conn
        |> auth_conn(key)
        |> get(~p"/api/v1/knowledge/articles/#{target.id}/suggested_links?threshold=2")
        |> json_response(400)

      assert resp["error"]["message"] =~ "threshold"
    end

    test "tenant isolation: another tenant's article is not found", %{conn: conn} do
      {_tenant_a, key_a} = setup_tenant_key()
      tenant_b = fixture(:tenant)
      b = embedded(tenant_b.id, "B", [1.0])

      conn
      |> auth_conn(key_a)
      |> get(~p"/api/v1/knowledge/articles/#{b.id}/suggested_links")
      |> json_response(404)
    end
  end

  # US-27.3: a DB statement-timeout (57014) on the pgvector scan must surface as
  # a pinned 504 (code "db_statement_timeout") with a SQLSTATE-bearing error log
  # carrying the request_id — NOT a blanket 500 that erases the SQLSTATE. The
  # incident origin (#170/#172) took 4 attempts to diagnose precisely because
  # the SQLSTATE was lost.
  describe "DB statement-timeout surfacing (AC-27.3.1 / .3 / .4, TC-27.3.1)" do
    import ExUnit.CaptureLog, only: [with_log: 1]
    import Mox

    setup :verify_on_exit!

    # A `Postgrex.Error` shaped exactly as Postgrex builds a real 57014 (the
    # probe in scratchpad confirmed `code: :query_canceled, pg_code: "57014"`).
    # `query:` carries SQL + a vector literal that WOULD leak if anything called
    # Exception.message/1 — the no-leak assertions below prove we don't.
    defp statement_timeout_error do
      %Postgrex.Error{
        postgres: %{
          code: :query_canceled,
          pg_code: "57014",
          severity: "ERROR",
          message: "canceling statement due to statement timeout"
        },
        query: "SELECT id FROM articles ORDER BY embedding <=> '[0.123,0.456]'::vector LIMIT 5"
      }
    end

    # Inject the 57014 deterministically via the SuggestLinksBehaviour DI seam
    # (config/test.exs + Mox). A REAL timeout depends on wall-clock vs. the
    # statement_timeout and is not reproducible in the test harness — which is
    # exactly why the #170/#172 prod incident took 4 attempts to diagnose. The
    # mock raises the same %Postgrex.Error{} the real query would, so the full
    # HTTP stack (controller rescue -> FallbackController -> 504 + log) is
    # exercised end-to-end.
    test "57014 -> 504 db_statement_timeout, safe body, sqlstate+request_id logged",
         %{conn: conn} do
      {tenant, key} = setup_tenant_key()
      target = embedded(tenant.id, "Target", [1.0, 0.0])

      expect(Loopctl.MockSuggestLinks, :suggest_links_with_meta, fn _tenant, _article, _opts ->
        raise statement_timeout_error()
      end)

      {resp_conn, log} =
        with_log(fn ->
          conn
          |> auth_conn(key)
          |> get(~p"/api/v1/knowledge/articles/#{target.id}/suggested_links")
        end)

      assert resp_conn.status == 504
      body = json_response(resp_conn, 504)
      assert body["error"]["status"] == 504
      assert body["error"]["code"] == "db_statement_timeout"
      assert is_binary(body["error"]["message"])

      # Body never leaks SQL / vector / params / stack (AC-27.3.2 / .8).
      raw = resp_conn.resp_body
      refute raw =~ "SELECT"
      refute raw =~ "embedding <=>"
      refute raw =~ "::vector"
      refute raw =~ "0.123"

      # Structured log carries the real SQLSTATE and the mapped code (AC-27.3.3).
      assert log =~ "sqlstate=57014"
      assert log =~ "mapped_code=db_statement_timeout"

      # request_id is a REAL captured value, not just the bare `request_id=` label
      # (Plug.RequestId populates it on this path). Asserting against the actual
      # response header proves the id is threaded — a regression that drops it
      # would surface as `request_id=` (empty/nil) and fail this, where a bare
      # `=~ "request_id="` substring check would not.
      rid = resp_conn |> get_resp_header("x-request-id") |> List.first()
      assert is_binary(rid) and rid != ""
      assert log =~ "request_id=#{rid}"

      # tenant_id is a required AC-27.3.3 correlation field — assert the seeded
      # tenant id is present so a rename of the current_api_key assign (the source
      # of db_error_tenant_id/1) can't silently drop tenant correlation.
      assert log =~ "tenant_id=#{tenant.id}"

      # And does NOT leak the vector literal / bound params (AC-27.3.8).
      refute log =~ "::vector"
      refute log =~ "embedding <=>"
      refute log =~ "0.123"
    end

    # TC-27.3.2: an unmapped SQLSTATE Postgrex.Error surfaces as a generic 500
    # with the real sqlstate logged (not erased), proving the catch-all path.
    test "unmapped Postgrex.Error -> 500 db_error, real sqlstate logged (TC-27.3.2)",
         %{conn: conn} do
      {tenant, key} = setup_tenant_key()
      target = embedded(tenant.id, "Target", [1.0, 0.0])

      expect(Loopctl.MockSuggestLinks, :suggest_links_with_meta, fn _t, _a, _o ->
        raise %Postgrex.Error{
          postgres: %{
            code: :undefined_table,
            pg_code: "42P01",
            severity: "ERROR",
            message: "relation does not exist"
          }
        }
      end)

      {resp_conn, log} =
        with_log(fn ->
          conn
          |> auth_conn(key)
          |> get(~p"/api/v1/knowledge/articles/#{target.id}/suggested_links")
        end)

      assert resp_conn.status == 500
      body = json_response(resp_conn, 500)
      assert body["error"]["code"] == "db_error"
      assert log =~ "sqlstate=42P01"
      assert log =~ "mapped_code=db_error"
    end

    # Finding #2 (US-27.3): a serialization failure (40001) on the RESCUE path
    # surfaces as a 503 with the PRECISE code db_serialization_failure (not the
    # coarse db_unavailable). The escaped/backstop path now matches this via the
    # SanitizedDBError mapped_code (see db_error_backstop_test.exs), so the 503
    # `code` no longer diverges between the two paths.
    test "40001 -> 503 db_serialization_failure (precise code, Retry-After), sqlstate logged",
         %{conn: conn} do
      {tenant, key} = setup_tenant_key()
      target = embedded(tenant.id, "Target", [1.0, 0.0])

      expect(Loopctl.MockSuggestLinks, :suggest_links_with_meta, fn _t, _a, _o ->
        raise %Postgrex.Error{
          postgres: %{
            code: :serialization_failure,
            pg_code: "40001",
            severity: "ERROR",
            message: "could not serialize access due to concurrent update"
          }
        }
      end)

      {resp_conn, log} =
        with_log(fn ->
          conn
          |> auth_conn(key)
          |> get(~p"/api/v1/knowledge/articles/#{target.id}/suggested_links")
        end)

      assert resp_conn.status == 503
      body = json_response(resp_conn, 503)
      assert body["error"]["code"] == "db_serialization_failure"
      assert get_resp_header(resp_conn, "retry-after") != []
      assert log =~ "sqlstate=40001"
      assert log =~ "mapped_code=db_serialization_failure"
    end

    # A pool checkout / connection drop surfaces as a retryable 503 with
    # Retry-After, distinct from a logic 500.
    test "DBConnection.ConnectionError -> 503 db_unavailable with Retry-After",
         %{conn: conn} do
      {tenant, key} = setup_tenant_key()
      target = embedded(tenant.id, "Target", [1.0, 0.0])

      expect(Loopctl.MockSuggestLinks, :suggest_links_with_meta, fn _t, _a, _o ->
        raise %DBConnection.ConnectionError{message: "tcp closed"}
      end)

      resp_conn =
        conn
        |> auth_conn(key)
        |> get(~p"/api/v1/knowledge/articles/#{target.id}/suggested_links")

      assert resp_conn.status == 503
      body = json_response(resp_conn, 503)
      assert body["error"]["code"] == "db_unavailable"
      assert get_resp_header(resp_conn, "retry-after") != []
    end
  end

  # TC-27.3.3 / AC-27.3.5 / .7: a missing or cross-tenant article still returns
  # 404 — never a DB-error code. Error mapping does not become an existence
  # oracle. (The happy-404 path is covered above; these reaffirm the boundary
  # alongside the DB-error handling so the two don't collide.)
  describe "anti-oracle boundary (AC-27.3.5 / .7, TC-27.3.3)" do
    test "non-existent article's suggested_links -> 404, not a DB-error code", %{conn: conn} do
      {_tenant, key} = setup_tenant_key()

      body =
        conn
        |> auth_conn(key)
        |> get(~p"/api/v1/knowledge/articles/#{Ecto.UUID.generate()}/suggested_links")
        |> json_response(404)

      assert body["error"]["status"] == 404
      refute body["error"]["code"] in ["db_statement_timeout", "db_error", "db_unavailable"]
    end

    test "cross-tenant article -> 404, not a DB-error code", %{conn: conn} do
      {_tenant_a, key_a} = setup_tenant_key()
      tenant_b = fixture(:tenant)
      b = embedded(tenant_b.id, "B", [1.0])

      body =
        conn
        |> auth_conn(key_a)
        |> get(~p"/api/v1/knowledge/articles/#{b.id}/suggested_links")
        |> json_response(404)

      assert body["error"]["status"] == 404
      refute body["error"]["code"] in ["db_statement_timeout", "db_error", "db_unavailable"]
    end

    # TC-27.4.1: the per-endpoint statement_timeout override fires a GENUINE 57014 on
    # the real HeavyRead path (not a fabricated error), and that surfaces as the
    # structured 504 db_statement_timeout at the HTTP boundary — proving
    # override config → real query → 57014 → 504 end-to-end through the controller.
    test "statement_timeout override -> real 57014 -> 504 db_statement_timeout at HTTP",
         %{conn: conn} do
      {tenant, key} = setup_tenant_key()
      target = embedded(tenant.id, "Target", [1.0, 0.0])

      # The DI seam runs the REAL override→timeout path: a tight 50ms SET LOCAL
      # statement_timeout on a deliberately slow, tenant-scoped query → genuine
      # query_canceled (57014), bounded near 50ms (never the full 1s sleep).
      expect(Loopctl.MockSuggestLinks, :suggest_links_with_meta, fn t, _a, _o ->
        slow =
          from(a in Loopctl.Knowledge.Article,
            where: a.tenant_id == ^t,
            where: fragment("pg_sleep(1) IS NULL")
          )

        Loopctl.HeavyRead.all(t, slow, statement_timeout: 50)
      end)

      {elapsed_us, resp_conn} =
        :timer.tc(fn ->
          conn
          |> auth_conn(key)
          |> get(~p"/api/v1/knowledge/articles/#{target.id}/suggested_links")
        end)

      assert resp_conn.status == 504
      body = json_response(resp_conn, 504)
      assert body["error"]["code"] == "db_statement_timeout"

      # Bounded near the 50ms server-side timeout, NOT held for the 1s pg_sleep
      # (generous CI headroom; the precise timing assertion is in the unit test).
      assert elapsed_us / 1_000 < 900,
             "request should fast-fail near the timeout, took #{elapsed_us / 1_000}ms"
    end
  end

  # Finding #4 (US-37.5 review): the user-facing OverloadedError → 429 render envelope
  # had NO end-to-end coverage. This asserts a REAL heavy read shed over the per-tenant
  # in-flight cap surfaces as a 429 carrying the self-identifying
  # `code: "heavy_read_overloaded"` at the HTTP boundary (status mapping via
  # HeavyReadOverloadHandler → ErrorJSON "429.json"). Mirrors the 504 db-timeout e2e
  # above, but for the per-tenant shed.
  describe "per-tenant heavy-read overload -> 429 (US-37.5, AC-37.5.3)" do
    test "an over-cap tenant's heavy read surfaces as 429 heavy_read_overloaded", %{conn: conn} do
      {tenant, key} = setup_tenant_key()
      target = embedded(tenant.id, "Target", [1.0, 0.0])

      # Saturate this tenant's per-tenant in-flight slice so the very next wired heavy
      # read is shed. The DataCase default stub routes suggest_links_with_meta to the
      # REAL Knowledge path, whose read runs with the default `on_overload: :raise` (an
      # API read). Unlike a DB-timeout (which the controller rescues into a tuple),
      # OverloadedError is NOT rescued — it propagates to Phoenix render_errors, which
      # maps it via HeavyReadOverloadHandler → 429 and re-raises, so this asserts the
      # SENT error response with `assert_error_sent`.
      cap = TenantGate.cap()
      assert TenantGate.acquire(tenant.id, cap, cap) == :ok

      {429, _headers, body} =
        assert_error_sent(429, fn ->
          conn
          |> auth_conn(key)
          |> get(~p"/api/v1/knowledge/articles/#{target.id}/suggested_links")
        end)

      decoded = Jason.decode!(body)
      assert decoded["error"]["status"] == 429
      assert decoded["error"]["code"] == "heavy_read_overloaded"

      TenantGate.release(tenant.id, cap)
    end
  end
end
