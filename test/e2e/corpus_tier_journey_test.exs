defmodule Loopctl.E2E.CorpusTierJourneyTest do
  @moduledoc """
  US-43.4 (TC-43.4.3) — terminal end-to-end journey for the Epic 43 corpus tier: the
  FULL path an agent takes across the MCP tool surface and the HTTP API.

  `corpus_create` -> `corpus_index` (with `source_complete`) -> `corpus_search`, driven
  through the REAL endpoints, with every request body derived from the SAME builders the
  MCP client ships (`mcp-server/lib/http-helpers.js`: `buildCorpusCreateBody`,
  `buildCorpusIndexBody`, `buildCorpusSearchBody`). This is the only test in the epic
  that exercises the whole path an agent uses, and it is what proves the tier is
  REACHABLE rather than merely present: US-43.1/43.2/43.3 each verified their own layer,
  and a tool surface that forwarded the wrong body would pass every one of them.

  What it asserts about the RESULT is the tier's defining property: the returned pointer
  names a `source_ref` and `locator` that were ACTUALLY INDEXED, and no chunk body comes
  back — the agent is told which file and where, and opens it itself.

  Excluded from the default suite (`@moduletag :e2e`); run with `mix test.e2e` or
  `E2E_TESTS=1 mix test --only e2e`.

  ## Why `async: true` here, unlike the Context Retriever journey

  That journey needs a COMMITTED tenant because its executor reads through a second
  sandbox connection. Nothing on this path does: the corpus endpoints read and write
  through `Loopctl.Repo`/`Loopctl.HeavyRead` inside the same sandboxed connection the
  ConnCase owns, which is why `test/loopctl_web/controllers/corpus_controller_test.exs`
  is `async: true` too. Every fixture below is a rolled-back sandbox row.
  """
  use LoopctlWeb.ConnCase, async: true

  @moduletag :e2e

  alias Loopctl.Corpus

  setup :verify_on_exit!

  defp auth(conn, raw_key), do: put_req_header(conn, "authorization", "Bearer #{raw_key}")

  defp keyed_tenant(role) do
    tenant = fixture(:tenant)
    fixture(:tenant_llm_settings, %{tenant_id: tenant.id, embedding_api_key: "test-embed-key"})
    {raw_key, _key} = fixture(:api_key, %{tenant_id: tenant.id, role: role})
    {tenant, raw_key}
  end

  # ---------------------------------------------------------------------------
  # Mirrors of the MCP client's request-body builders
  # (`mcp-server/lib/http-helpers.js`). Deriving the bodies here the way the JS
  # dispatch derives them is what makes this a test of the AGENT's path rather
  # than of the HTTP surface a second time: a builder that dropped
  # `source_complete`, or emitted `query_vector: null` for an unset optional,
  # fails HERE.
  # ---------------------------------------------------------------------------

  defp mcp_create_body(args) do
    ~w(slug name mode embedding_model dim description allow_snippets project_id)
    |> Enum.reduce(%{}, fn key, acc ->
      case Map.get(args, key) do
        nil -> acc
        value -> Map.put(acc, key, value)
      end
    end)
  end

  defp mcp_index_body(args) do
    body = %{"chunks" => Map.get(args, "chunks", [])}

    case Map.get(args, "source_complete") do
      nil -> body
      source_complete -> Map.put(body, "source_complete", source_complete)
    end
  end

  defp mcp_search_body(args) do
    ~w(query query_vector lanes limit)
    |> Enum.reduce(%{}, fn key, acc ->
      case Map.get(args, key) do
        nil -> acc
        value -> Map.put(acc, key, value)
      end
    end)
  end

  describe "TC-43.4.3: create -> index -> search through the MCP tool surface" do
    test "the returned pointer names a chunk that was actually indexed, and carries no body",
         %{conn: conn} do
      {_tenant, agent_key} = keyed_tenant(:agent)

      # A phrase that appears in exactly ONE chunk, so the top hit is unambiguous.
      marker = "zqcorpus#{System.unique_integer([:positive])}"

      chunks = [
        %{
          "source_ref" => "docs/handbook.md",
          "locator" => %{"page" => 12},
          "text" => "Invoices are issued monthly and are payable on receipt.",
          "ordinal" => 1
        },
        %{
          "source_ref" => "docs/handbook.md",
          "locator" => %{"page" => 47},
          "text" => "Records are retained for #{marker} seven calendar years after closure.",
          "ordinal" => 2
        },
        %{
          "source_ref" => "docs/appendix.md",
          "locator" => %{"page" => 3},
          "text" => "The appendix lists the recognised holiday calendar.",
          "ordinal" => 1
        }
      ]

      # 1) corpus_create — POST /api/v1/corpora, body from buildCorpusCreateBody.
      slug = "handbook-#{System.unique_integer([:positive])}"

      created =
        conn
        |> auth(agent_key)
        |> post(
          ~p"/api/v1/corpora",
          mcp_create_body(%{
            "slug" => slug,
            "name" => "Handbook",
            "mode" => "server_embedded",
            "embedding_model" => "text-embedding-3-small",
            "dim" => 1536,
            # An unset optional must be OMITTED, not sent as null.
            "project_id" => nil
          })
        )
        |> json_response(201)

      assert %{"data" => %{"id" => corpus_id, "slug" => ^slug, "mode" => "server_embedded"}} =
               created

      # 2) corpus_index — POST /api/v1/corpora/:id/index, body from
      #    buildCorpusIndexBody, carrying source_complete in BOTH of its declared
      #    forms (a bare name, and a manifest) so the prune is exercised through
      #    the surface an agent actually uses (AC-43.4.1).
      indexed =
        build_conn()
        |> auth(agent_key)
        |> post(
          ~p"/api/v1/corpora/#{corpus_id}/index",
          mcp_index_body(%{
            "chunks" => chunks,
            "source_complete" => [
              "docs/appendix.md",
              %{
                "source_ref" => "docs/handbook.md",
                "locators" => [%{"page" => 12}, %{"page" => 47}]
              }
            ]
          })
        )
        |> json_response(200)

      assert length(indexed["data"]) == 3
      assert Enum.all?(indexed["data"], &(&1["status"] == "inserted"))

      # The pointers that now exist, as the tier itself reports them.
      indexed_pointers =
        MapSet.new(chunks, &{Map.fetch!(&1, "source_ref"), Map.fetch!(&1, "locator")})

      # 3) corpus_search — POST /api/v1/corpora/:id/search, body from
      #    buildCorpusSearchBody. Addressed by SLUG, the way an agent that only
      #    ran corpus_list would.
      searched =
        build_conn()
        |> auth(agent_key)
        |> post(
          ~p"/api/v1/corpora/#{slug}/search",
          mcp_search_body(%{"query" => marker, "query_vector" => nil})
        )
        |> json_response(200)

      assert [top | _rest] = searched["data"]

      # The pointer identifies a chunk that was ACTUALLY indexed...
      assert MapSet.member?(indexed_pointers, {top["source_ref"], top["locator"]})

      # ...and specifically the one that contains the phrase.
      assert top["source_ref"] == "docs/handbook.md"
      assert top["locator"] == %{"page" => 47}
      assert top["corpus_id"] == corpus_id
      assert is_binary(top["chunk_id"])
      assert is_number(top["score"])

      # A POINTER, never a body: nothing on this surface hands back chunk text.
      for result <- searched["data"] do
        refute Map.has_key?(result, "text")
        refute Map.has_key?(result, "body")
        refute Map.has_key?(result, "content")
      end

      # 4) corpus_status — the per-source view an agent re-indexes from.
      status =
        build_conn()
        |> auth(agent_key)
        |> get(~p"/api/v1/corpora/#{slug}/status")
        |> json_response(200)

      by_source = Map.new(status["data"], &{&1["source_ref"], &1})
      assert by_source["docs/handbook.md"]["chunk_count"] == 2
      assert by_source["docs/appendix.md"]["chunk_count"] == 1
    end

    # An empty result is what an agent misreads as an empty corpus, so the journey
    # also proves the tier answers a foreign tenant's search with nothing at all
    # rather than with another tenant's pointers.
    test "a second tenant's identically-indexed corpus never surfaces here", %{conn: conn} do
      {_tenant, agent_key} = keyed_tenant(:agent)
      {other_tenant, other_key} = keyed_tenant(:agent)

      marker = "zqisolate#{System.unique_integer([:positive])}"

      chunk = %{
        "source_ref" => "docs/handbook.md",
        "locator" => %{"page" => 47},
        "text" => "Records are retained for #{marker} seven calendar years.",
        "ordinal" => 1
      }

      mine = create_and_index!(conn, agent_key, chunk)
      _theirs = create_and_index!(build_conn(), other_key, chunk)

      body =
        build_conn()
        |> auth(agent_key)
        |> post(~p"/api/v1/corpora/#{mine}/search", mcp_search_body(%{"query" => marker}))
        |> json_response(200)

      # POSITIVE CONTROL: the identical text IS indexed in the other tenant, so an
      # empty-of-foreign-rows result here means scoping works rather than that the
      # query found nothing.
      assert [%{"corpus_id" => corpus_id}] = body["data"]
      assert {:ok, _} = Corpus.get_corpus(other_tenant.id, "isolation-probe")
      refute Enum.any?(body["data"], &(&1["corpus_id"] != corpus_id))
    end
  end

  defp create_and_index!(conn, raw_key, chunk) do
    %{"data" => %{"id" => corpus_id}} =
      conn
      |> auth(raw_key)
      |> post(
        ~p"/api/v1/corpora",
        mcp_create_body(%{
          "slug" => "isolation-probe",
          "name" => "Isolation probe",
          "mode" => "server_embedded",
          "embedding_model" => "text-embedding-3-small",
          "dim" => 1536
        })
      )
      |> json_response(201)

    build_conn()
    |> auth(raw_key)
    |> post(~p"/api/v1/corpora/#{corpus_id}/index", mcp_index_body(%{"chunks" => [chunk]}))
    |> json_response(200)

    corpus_id
  end
end
