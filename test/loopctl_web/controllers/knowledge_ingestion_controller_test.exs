defmodule LoopctlWeb.KnowledgeIngestionControllerTest do
  use LoopctlWeb.ConnCase, async: true

  alias Loopctl.AdminRepo
  alias Loopctl.Ingestion.ContentEnvelope
  alias Loopctl.Knowledge
  alias Loopctl.Oban.FairShare
  alias Loopctl.ObanConfig
  alias Loopctl.Repo

  setup :verify_on_exit!

  # US-36.3: seed `count` in-flight (non-terminal) :ingestion ContentIngestionWorker
  # rows for a tenant so its backlog crosses the OBAN_INGEST_BACKLOG_MAX threshold.
  # oban_jobs is Oban-owned + has no RLS, so we insert through AdminRepo (exactly as
  # FairShare.in_flight_count/2 reads). A raw insert does NOT run the job (unlike
  # Oban.insert under :inline), which is what we need to simulate a piled-up backlog.
  # "available" is a non-terminal state counted by in_flight_count/2.
  defp seed_ingestion_backlog(tenant_id, count) do
    now = DateTime.utc_now()

    entries =
      for _ <- 1..count do
        %{
          state: "available",
          queue: "ingestion",
          worker: "Loopctl.Workers.ContentIngestionWorker",
          args: %{"tenant_id" => tenant_id},
          attempt: 0,
          max_attempts: 20,
          priority: 0,
          inserted_at: now,
          scheduled_at: now
        }
      end

    {^count, _} = AdminRepo.insert_all(Oban.Job, entries)
    :ok
  end

  defp auth_conn(conn, raw_key) do
    put_req_header(conn, "authorization", "Bearer #{raw_key}")
  end

  # The single persisted ContentIngestionWorker row for a tenant. Oban.insert writes
  # through `Loopctl.Repo` in the test process, so read it back via the SAME repo (a
  # cross-repo AdminRepo read would miss the sandbox-scoped row); oban_jobs has no RLS.
  # Asserts exactly one, so a stray/duplicate enqueue fails loudly.
  defp ingestion_job_for(tenant_id) do
    [job] =
      Oban.Job
      |> Repo.all()
      |> Enum.filter(
        &(&1.worker == "Loopctl.Workers.ContentIngestionWorker" and
            &1.args["tenant_id"] == tenant_id)
      )

    job
  end

  # Mandatory BYO (Epic 28, #179): ingest requires the tenant to have configured an
  # Anthropic key. Every existing ingest test needs a keyed tenant; the dedicated
  # "no key -> 422" test creates a keyless tenant directly.
  defp keyed_tenant do
    t = fixture(:tenant, %{})
    fixture(:tenant_llm_settings, %{tenant_id: t.id})
    t
  end

  # A verb+path pair (as printed in a remediation string) is a real router route.
  defp route_registered?(verb, path) do
    wanted = verb |> String.downcase() |> String.to_existing_atom()

    Enum.any?(LoopctlWeb.Router.__routes__(), fn route ->
      route.verb == wanted and route.path == path
    end)
  end

  # Oban runs :inline in tests, so the ingestion worker executes within the
  # request; stub the extractor to yield exactly one article so we can assert the
  # resulting article's status (draft by default, published with publish: true).
  defp expect_one_extracted_article(title) do
    expect(Loopctl.MockContentExtractor, :extract_from_content, fn _tenant_id, _content, _opts ->
      {:ok, [%{title: title, body: "Body for #{title}.", category: :pattern, tags: ["t"]}]}
    end)
  end

  # --- Mandatory BYO gate at the HTTP boundary (Epic 28, #179 — review #7) ---

  describe "mandatory BYO 422 gate" do
    test "POST /knowledge/ingest with a keyless tenant -> 422 code no_api_key", %{conn: conn} do
      # A tenant WITHOUT an llm settings row (no key configured).
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})

      # The extractor must never run — we reject before enqueuing.
      expect(Loopctl.MockContentExtractor, :extract_from_content, 0, fn _t, _c, _o ->
        flunk("extractor must not run without a tenant key")
      end)

      body =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/knowledge/ingest", %{content: "x", source_type: "newsletter"})
        |> json_response(422)

      assert body["error"]["code"] == "no_api_key"
      assert body["error"]["message"] =~ "Anthropic API key"

      # Self-service remediation: the agent must be able to onboard from the response
      # ALONE — it names the set_llm_config MCP tool, the missing credential, a
      # copy-paste example, and the REST endpoint.
      remediation = body["error"]["remediation"]
      assert remediation["action"] == "configure_llm"
      assert remediation["missing"] == ["api_key"]
      assert remediation["mcp_tool"] == "set_llm_config"
      assert remediation["example"] =~ "set_llm_config"
      assert is_binary(remediation["docs"])

      # The remediation's `api` must name a verb+path ACTUALLY registered in the
      # router (review #7 — catches PUT/PATCH drift between the copy and the route).
      [verb, path] = String.split(remediation["api"], " ", parts: 2)

      assert route_registered?(verb, path),
             "422 remediation names #{verb} #{path}, which is not a registered route"

      # Never leaks a key/secret.
      refute inspect(body) =~ ~r/sk-[A-Za-z0-9]{8}/
    end

    test "POST /knowledge/ingest/batch with a keyless tenant -> 422 code no_api_key", %{
      conn: conn
    } do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})

      body =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/knowledge/ingest/batch", %{
          items: [%{content: "x", source_type: "newsletter"}]
        })
        |> json_response(422)

      assert body["error"]["code"] == "no_api_key"
    end
  end

  # --- POST /api/v1/knowledge/ingest ---

  describe "POST /api/v1/knowledge/ingest" do
    test "queues ingestion job with URL", %{conn: conn} do
      tenant = keyed_tenant()
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/knowledge/ingest", %{
          url: "https://example.com/article",
          source_type: "web_article"
        })

      body = json_response(conn, 202)
      assert body["data"]["status"] == "queued"
      assert is_binary(body["data"]["content_hash"])
      assert body["data"]["source_type"] == "web_article"
      assert is_binary(body["data"]["inserted_at"] |> to_string())
    end

    test "queues ingestion job with inline content", %{conn: conn} do
      tenant = keyed_tenant()
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/knowledge/ingest", %{
          content: "Some raw content about patterns and conventions",
          source_type: "newsletter"
        })

      body = json_response(conn, 202)
      assert body["data"]["status"] == "queued"
      assert body["data"]["source_type"] == "newsletter"
    end

    test "#493: inline content is encrypted at rest in oban_jobs args (never plaintext)",
         %{conn: conn} do
      tenant = keyed_tenant()
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})
      plaintext = "confidential document body that must never sit plaintext in oban_jobs"

      # :manual so the job is PERSISTED (not run inline), letting us inspect the args
      # actually written to oban_jobs. No extractor stub — the worker never runs here.
      Oban.Testing.with_testing_mode(:manual, fn ->
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/knowledge/ingest", %{content: plaintext, source_type: "newsletter"})
        |> json_response(202)
      end)

      job = ingestion_job_for(tenant.id)

      # The plaintext appears NOWHERE in the persisted args JSON.
      refute Map.has_key?(job.args, "content")
      refute String.contains?(Jason.encode!(job.args), "confidential document body")

      # The encrypted envelope is present and decrypts back to the original plaintext.
      assert is_binary(job.args["content_encrypted"])
      refute job.args["content_encrypted"] == plaintext
      assert {:ok, ^plaintext} = ContentEnvelope.unwrap(job.args["content_encrypted"])
    end

    test "#493 finding 4: a non-string content is a clean 422, not a 500", %{conn: conn} do
      tenant = keyed_tenant()
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/knowledge/ingest", %{
          "content" => %{"x" => 1},
          "source_type" => "newsletter"
        })

      body = json_response(conn, 422)
      assert body["error"]["message"] =~ "must be strings"
    end

    test "#493 findings 5/7: oversized inline content is rejected with 422", %{conn: conn} do
      tenant = keyed_tenant()
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})
      oversized = String.duplicate("a", 1_000_001)

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/knowledge/ingest", %{
          content: oversized,
          source_type: "newsletter"
        })

      body = json_response(conn, 422)
      assert body["error"]["message"] =~ "inline limit"
    end

    test "#493 finding 6: encrypted inline job carries a cleartext content_chunk_count",
         %{conn: conn} do
      tenant = keyed_tenant()
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})

      Oban.Testing.with_testing_mode(:manual, fn ->
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/knowledge/ingest", %{
          content: "Some raw content about patterns.",
          source_type: "newsletter"
        })
        |> json_response(202)
      end)

      job = ingestion_job_for(tenant.id)
      assert is_integer(job.args["content_chunk_count"])
      assert job.args["content_chunk_count"] >= 1
    end

    test "#493 findings 1/8: content_hash is a keyed blind index, not sha256(plaintext)",
         %{conn: conn} do
      tenant = keyed_tenant()
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})
      plaintext = "guessable memo content"

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/knowledge/ingest", %{content: plaintext, source_type: "newsletter"})

      content_hash = json_response(conn, 202)["data"]["content_hash"]
      bare_sha256 = :crypto.hash(:sha256, plaintext) |> Base.encode16(case: :lower)

      # An attacker with DB read access must NOT be able to confirm-by-match with a
      # plain sha256 of the known plaintext.
      refute content_hash == bare_sha256
    end

    test "URL ingests carry no inline content key in args (#493)", %{conn: conn} do
      tenant = keyed_tenant()
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})

      Oban.Testing.with_testing_mode(:manual, fn ->
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/knowledge/ingest", %{
          url: "https://example.com/article",
          source_type: "web_article"
        })
        |> json_response(202)
      end)

      job = ingestion_job_for(tenant.id)

      refute Map.has_key?(job.args, "content")
      refute Map.has_key?(job.args, "content_encrypted")
      assert job.args["url"] == "https://example.com/article"
    end

    test "extracted articles default to draft", %{conn: conn} do
      tenant = keyed_tenant()
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})
      expect_one_extracted_article("Drafted by ingest")

      conn
      |> auth_conn(raw_key)
      |> post(~p"/api/v1/knowledge/ingest", %{content: "raw", source_type: "newsletter"})
      |> json_response(202)

      %{data: [article]} = Knowledge.list_articles(tenant.id, source_type: "newsletter")
      assert article.status == :draft
    end

    test "publish: true publishes the extracted articles", %{conn: conn} do
      tenant = keyed_tenant()
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})
      expect_one_extracted_article("Published by ingest")

      conn
      |> auth_conn(raw_key)
      |> post(~p"/api/v1/knowledge/ingest", %{
        content: "raw",
        source_type: "newsletter",
        publish: true
      })
      |> json_response(202)

      %{data: [article]} = Knowledge.list_articles(tenant.id, source_type: "newsletter")
      assert article.status == :published
    end

    test "returns 422 when both url and content provided", %{conn: conn} do
      tenant = keyed_tenant()
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/knowledge/ingest", %{
          url: "https://example.com",
          content: "Some content",
          source_type: "newsletter"
        })

      body = json_response(conn, 422)
      assert body["error"]["message"] =~ "exactly one"
    end

    test "returns 422 when neither url nor content provided", %{conn: conn} do
      tenant = keyed_tenant()
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/knowledge/ingest", %{
          source_type: "newsletter"
        })

      body = json_response(conn, 422)
      assert body["error"]["message"] =~ "required"
    end

    test "returns 422 when source_type missing", %{conn: conn} do
      tenant = keyed_tenant()
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/knowledge/ingest", %{
          content: "Some content"
        })

      body = json_response(conn, 422)
      assert body["error"]["message"] =~ "source_type"
    end

    # SSRF egress guard (worker-01 / GHSA-j7m9-ffmr-pwhm): a URL pointing at a
    # private / loopback / cloud-metadata address is rejected 4xx up front, before
    # any job is enqueued or fetched.
    test "returns 422 for a URL targeting the cloud metadata endpoint", %{conn: conn} do
      tenant = keyed_tenant()
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/knowledge/ingest", %{
          url: "http://169.254.169.254/latest/meta-data/",
          source_type: "web_article"
        })

      body = json_response(conn, 422)
      assert body["error"]["message"] =~ "private, loopback, or metadata"
    end

    test "returns 422 for a decimal-encoded loopback URL", %{conn: conn} do
      tenant = keyed_tenant()
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/knowledge/ingest", %{
          url: "http://2130706433/secret",
          source_type: "web_article"
        })

      assert json_response(conn, 422)["error"]["message"] =~ "private, loopback, or metadata"
    end

    test "returns 422 for a v4-in-v6 NAT64-embedded metadata URL", %{conn: conn} do
      tenant = keyed_tenant()
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/knowledge/ingest", %{
          url: "http://[64:ff9b::a9fe:a9fe]/latest/meta-data/",
          source_type: "web_article"
        })

      assert json_response(conn, 422)["error"]["message"] =~ "private, loopback, or metadata"
    end

    test "returns 422 with a distinct message when the host cannot be resolved", %{conn: conn} do
      tenant = keyed_tenant()
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})

      expect(Loopctl.MockDnsResolver, :resolve, fn _host -> {:error, :nxdomain} end)

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/knowledge/ingest", %{
          url: "https://does-not-resolve.example.com/x",
          source_type: "web_article"
        })

      message = json_response(conn, 422)["error"]["message"]
      assert message =~ "could not be resolved"
      refute message =~ "private, loopback, or metadata"
    end

    test "agent role is rejected (requires orchestrator)", %{conn: conn} do
      tenant = keyed_tenant()
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/knowledge/ingest", %{
          content: "Some content",
          source_type: "newsletter"
        })

      assert json_response(conn, 403)
    end

    test "user role is allowed (higher than orchestrator)", %{conn: conn} do
      tenant = keyed_tenant()
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/knowledge/ingest", %{
          content: "Some content for user",
          source_type: "newsletter"
        })

      body = json_response(conn, 202)
      assert body["data"]["status"] == "queued"
    end

    test "unauthenticated returns 401", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/knowledge/ingest", %{
          content: "Some content",
          source_type: "newsletter"
        })

      assert json_response(conn, 401)
    end

    test "includes project_id in job args when provided", %{conn: conn} do
      tenant = keyed_tenant()
      project = fixture(:project, %{tenant_id: tenant.id})
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/knowledge/ingest", %{
          content: "Project-scoped content",
          source_type: "skill",
          project_id: project.id
        })

      assert json_response(conn, 202)
    end

    test "returns 422 for a malformed project_id (not enqueued, kbweb-01)", %{conn: conn} do
      tenant = keyed_tenant()
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/knowledge/ingest", %{
          content: "Some content",
          source_type: "newsletter",
          project_id: "not-a-uuid"
        })

      body = json_response(conn, 422)
      assert body["error"]["message"] =~ "project_id"
    end

    test "returns 422 for a non-string (array) project_id (not enqueued)", %{conn: conn} do
      tenant = keyed_tenant()
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/knowledge/ingest", %{
          content: "Some content",
          source_type: "newsletter",
          project_id: ["x"]
        })

      body = json_response(conn, 422)
      assert body["error"]["message"] =~ "project_id"
    end

    test "an empty-string project_id is accepted as tenant-wide (202)", %{conn: conn} do
      tenant = keyed_tenant()
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})
      expect_one_extracted_article("Blank pid ingest")

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/knowledge/ingest", %{
          content: "Blank pid content",
          source_type: "newsletter",
          project_id: ""
        })

      assert json_response(conn, 202)
    end
  end

  # --- POST /api/v1/knowledge/ingest/batch ---

  describe "POST /api/v1/knowledge/ingest/batch" do
    test "queues all three items successfully", %{conn: conn} do
      tenant = keyed_tenant()
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})

      items = [
        %{content: "Batch item one content", source_type: "newsletter"},
        %{content: "Batch item two content", source_type: "newsletter"},
        %{content: "Batch item three content", source_type: "newsletter"}
      ]

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/knowledge/ingest/batch", %{items: items})

      body = json_response(conn, 200)
      assert is_list(body["data"])
      assert length(body["data"]) == 3
      assert Enum.all?(body["data"], fn r -> r["status"] == "queued" end)
      assert Enum.all?(body["data"], fn r -> is_binary(r["content_hash"]) end)
    end

    test "returns per-item results for duplicate items within the same batch", %{conn: conn} do
      tenant = keyed_tenant()
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})

      items = [
        %{content: "Duplicate content", source_type: "newsletter"},
        %{content: "Duplicate content", source_type: "newsletter"},
        %{content: "Unique content", source_type: "newsletter"}
      ]

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/knowledge/ingest/batch", %{items: items})

      body = json_response(conn, 200)
      assert length(body["data"]) == 3

      statuses = Enum.map(body["data"], & &1["status"])
      # In inline test mode jobs complete synchronously, so Oban uniqueness
      # (which excludes completed jobs) cannot flag duplicates within the same
      # request. The important batch-endpoint guarantee we assert here is that
      # every item receives a per-item result (queued or already_queued), never
      # error, and that duplicate content_hashes produce identical hashes.
      assert Enum.all?(statuses, &(&1 in ["queued", "already_queued"]))

      hashes =
        body["data"]
        |> Enum.take(2)
        |> Enum.map(& &1["content_hash"])

      [h1, h2] = hashes
      assert h1 == h2
    end

    test "returns 422 when batch exceeds 50 items", %{conn: conn} do
      tenant = keyed_tenant()
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})

      items =
        Enum.map(1..51, fn i ->
          %{content: "Item #{i}", source_type: "newsletter"}
        end)

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/knowledge/ingest/batch", %{items: items})

      body = json_response(conn, 422)
      assert body["error"]["message"] =~ "50"
    end

    test "returns 422 when items is empty", %{conn: conn} do
      tenant = keyed_tenant()
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/knowledge/ingest/batch", %{items: []})

      assert json_response(conn, 422)
    end

    test "mixed valid and invalid items produce per-item results", %{conn: conn} do
      tenant = keyed_tenant()
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})

      items = [
        %{content: "Valid content", source_type: "newsletter"},
        # missing source_type
        %{content: "Invalid — no source_type"},
        # neither url nor content
        %{source_type: "newsletter"}
      ]

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/knowledge/ingest/batch", %{items: items})

      body = json_response(conn, 200)
      assert length(body["data"]) == 3

      statuses = Enum.map(body["data"], & &1["status"])
      assert "queued" in statuses
      assert Enum.count(statuses, &(&1 == "error")) == 2
    end

    test "agent role is rejected (requires orchestrator)", %{conn: conn} do
      tenant = keyed_tenant()
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/knowledge/ingest/batch", %{
          items: [%{content: "x", source_type: "newsletter"}]
        })

      assert json_response(conn, 403)
    end

    # FIX 2 (worker-01 / GHSA-j7m9-ffmr-pwhm): a batch of URL items pointing at an
    # unresponsive nameserver must NOT tie up the request. Task.async_stream caps
    # each item at the (test-configured, short) per-item deadline and maps a hung
    # item to a validation_timeout error instead of hanging the whole batch.
    test "bounds the batch when the resolver hangs (validation_timeout, no hang)",
         %{conn: conn} do
      tenant = keyed_tenant()
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})

      # Resolver never returns → each item's pin exceeds the per-item deadline and
      # is killed. (Reaches the task via the $callers chain async_stream sets.)
      stub(Loopctl.MockDnsResolver, :resolve, fn _host -> Process.sleep(:infinity) end)

      items = [
        %{url: "https://slow-a.example.com/x", source_type: "web_article"},
        %{url: "https://slow-b.example.com/x", source_type: "web_article"}
      ]

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/knowledge/ingest/batch", %{items: items})

      body = json_response(conn, 200)
      assert length(body["data"]) == 2
      assert Enum.all?(body["data"], &(&1["status"] == "error"))
      assert Enum.all?(body["data"], &(&1["error"] == "validation_timeout"))
    end

    # FIX 1: a genuine (non-timeout) raise in ONE item must not crash the whole
    # request. async_stream_nolink monitors (not links) the task, so the raise
    # becomes a per-item validation_failed error while other items still succeed
    # and the request returns 200. Under the old bare Task.async_stream this
    # raise would have killed the request.
    @tag :capture_log
    test "a raising item yields validation_failed; other items still return 200",
         %{conn: conn} do
      tenant = keyed_tenant()
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})

      # One host makes the resolver raise; everything else resolves public.
      stub(Loopctl.MockDnsResolver, :resolve, fn
        "boom.example.com" -> raise "resolver boom"
        _host -> {:ok, [{93, 184, 216, 34}]}
      end)

      items = [
        %{url: "https://boom.example.com/x", source_type: "web_article"},
        %{content: "Valid inline content", source_type: "newsletter"}
      ]

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/knowledge/ingest/batch", %{items: items})

      body = json_response(conn, 200)
      assert length(body["data"]) == 2

      [first, second] = body["data"]
      # Ordering is preserved (ordered: true): item 1 failed, item 2 queued.
      assert first["status"] == "error"
      # The resolver is mocked to raise for boom.example.com. When the Mox stub
      # reaches the async_stream_nolink task the raise maps to "validation_failed";
      # but under the full parallel suite the stub can intermittently miss the
      # SUPERVISED task ($callers race for a Task.Supervisor child), the real
      # resolver then hangs on the fake host, and on_timeout: :kill_task maps it to
      # "validation_timeout". Both outcomes prove the guarantee under test — the bad
      # item is CONTAINED as a per-item validation error (request stays 200, the
      # good item still queues) instead of crashing the whole request — so assert
      # the validation-error CLASS, not the race-dependent exact mode.
      assert first["error"] in ["validation_failed", "validation_timeout"]
      assert second["status"] == "queued"
    end

    test "tenant isolation: tenant A cannot see tenant B's batch jobs", %{conn: conn} do
      tenant_a = keyed_tenant()
      tenant_b = keyed_tenant()
      {raw_key_a, _} = fixture(:api_key, %{tenant_id: tenant_a.id, role: :orchestrator})
      {raw_key_b, _} = fixture(:api_key, %{tenant_id: tenant_b.id, role: :orchestrator})

      # Tenant B batches two items
      build_conn()
      |> auth_conn(raw_key_b)
      |> post(~p"/api/v1/knowledge/ingest/batch", %{
        items: [
          %{content: "B batch 1", source_type: "newsletter"},
          %{content: "B batch 2", source_type: "newsletter"}
        ]
      })

      # Tenant A should not see tenant B's jobs
      conn =
        conn
        |> auth_conn(raw_key_a)
        |> get(~p"/api/v1/knowledge/ingestion-jobs")

      body = json_response(conn, 200)

      tenant_b_jobs =
        Enum.filter(body["data"], fn job ->
          job["args"]["tenant_id"] == tenant_b.id
        end)

      assert tenant_b_jobs == []
    end

    test "a malformed project_id yields a per-item error while valid items still queue (kbweb-01)",
         %{conn: conn} do
      tenant = keyed_tenant()
      project = fixture(:project, %{tenant_id: tenant.id})
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})

      items = [
        %{content: "Good item", source_type: "newsletter", project_id: project.id},
        %{content: "Poison item", source_type: "newsletter", project_id: "not-a-uuid"}
      ]

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/knowledge/ingest/batch", %{items: items})

      body = json_response(conn, 200)
      assert [good, bad] = body["data"]
      assert good["status"] == "queued"
      assert bad["status"] == "error"
      assert bad["error"] =~ "project_id"
    end
  end

  # --- US-36.3: batch-ingest backlog backpressure (429) ---

  # Forward the fail-open counter for THIS tenant to the test process, with guaranteed
  # detach. Scoped by tenant because the handler is process-GLOBAL and the suite is async.
  defp attach_failed_open(tenant_id) do
    test_pid = self()
    handler_id = "backlog-failopen-#{System.unique_integer([:positive])}"
    event = [:loopctl, :ingestion, :backlog_gate, :failed_open]

    :telemetry.attach(
      handler_id,
      event,
      fn ^event, measurements, metadata, _ ->
        if metadata.tenant_id == tenant_id,
          do: send(test_pid, {:backlog_failed_open, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  describe "POST /api/v1/knowledge/ingest/batch backlog backpressure (US-36.3)" do
    test "TC-36.3.1: tenant over threshold -> 429 + Retry-After + coded error; ZERO jobs enqueued",
         %{conn: conn} do
      tenant = keyed_tenant()
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})

      # Seed the tenant's in-flight :ingestion backlog to the real resolved threshold
      # (race-free: the gate reads the same env-derived value at call time — no global
      # env mutation needed for an async test).
      max = ObanConfig.ingest_backlog_max()
      :ok = seed_ingestion_backlog(tenant.id, max)
      before_count = FairShare.in_flight_count(tenant.id, :ingestion)
      assert before_count >= max

      # The extractor must never run — we reject before enqueuing anything.
      expect(Loopctl.MockContentExtractor, :extract_from_content, 0, fn _t, _c, _o ->
        flunk("extractor must not run when the batch is rejected for backlog backpressure")
      end)

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/knowledge/ingest/batch", %{
          items: [%{content: "Over-threshold batch item", source_type: "newsletter"}]
        })

      body = json_response(conn, 429)
      assert body["error"]["code"] == "ingestion_backlog_exceeded"
      assert body["error"]["status"] == 429
      assert body["error"]["message"] =~ "No items from this batch were enqueued"

      # Retry-After header is a positive integer string, tied to the ingestion drain
      # cadence (NOT the sub-second fair-share snooze base) so a compliant client does
      # not hot-loop retry->429.
      assert [retry_after] = get_resp_header(conn, "retry-after")
      assert {n, ""} = Integer.parse(retry_after)
      assert n > 0
      assert body["error"]["retry_after_seconds"] == n
      assert n == ObanConfig.ingest_backlog_retry_after_seconds()

      # All-or-nothing: NO new ContentIngestionWorker job was enqueued for the tenant.
      assert FairShare.in_flight_count(tenant.id, :ingestion) == before_count
    end

    test "TC-36.3.6: the SINGLE-item ingest path is gated too (no bypass of the valve)",
         %{conn: conn} do
      tenant = keyed_tenant()
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})

      max = ObanConfig.ingest_backlog_max()
      :ok = seed_ingestion_backlog(tenant.id, max)
      before_count = FairShare.in_flight_count(tenant.id, :ingestion)

      # Looping the single-item endpoint must NOT bypass the batch backpressure valve.
      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/knowledge/ingest", %{
          content: "Over-threshold single item",
          source_type: "newsletter"
        })

      body = json_response(conn, 429)
      assert body["error"]["code"] == "ingestion_backlog_exceeded"
      assert [_retry_after] = get_resp_header(conn, "retry-after")

      # No new job enqueued — the single-item path shed the request like the batch path.
      assert FairShare.in_flight_count(tenant.id, :ingestion) == before_count
    end

    test "TC-36.3.2: under the threshold, a normal batch enqueues as before (byte-for-byte)",
         %{conn: conn} do
      tenant = keyed_tenant()
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})

      # A little backlog, well under the threshold — the gate must not fire.
      :ok = seed_ingestion_backlog(tenant.id, 2)

      items = [
        %{content: "Under-threshold item one", source_type: "newsletter"},
        %{content: "Under-threshold item two", source_type: "newsletter"}
      ]

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/knowledge/ingest/batch", %{items: items})

      body = json_response(conn, 200)
      assert length(body["data"]) == 2
      assert Enum.all?(body["data"], fn r -> r["status"] == "queued" end)
    end

    test "TC-36.3.4: the check is tenant-scoped — A's backlog never blocks B",
         %{conn: conn} do
      tenant_a = keyed_tenant()
      tenant_b = keyed_tenant()
      {key_b, _} = fixture(:api_key, %{tenant_id: tenant_b.id, role: :orchestrator})

      # Tenant A is FAR over threshold; tenant B is empty.
      :ok = seed_ingestion_backlog(tenant_a.id, ObanConfig.ingest_backlog_max())
      assert FairShare.in_flight_count(tenant_b.id, :ingestion) == 0

      # B posts a valid batch and succeeds — A's backlog does not affect it (the count
      # fragment is scoped to args->>'tenant_id' = B only).
      conn =
        conn
        |> auth_conn(key_b)
        |> post(~p"/api/v1/knowledge/ingest/batch", %{
          items: [%{content: "Tenant B item", source_type: "newsletter"}]
        })

      body = json_response(conn, 200)
      assert length(body["data"]) == 1
      assert Enum.all?(body["data"], fn r -> r["status"] == "queued" end)
    end

    test "TC-36.3.5: the admission gate FAILS OPEN when the backlog count raises (no 500)",
         %{conn: conn} do
      # The count runs under a 2s statement_timeout on a fleet-wide (state,queue) index
      # scan, so during the deep-queue flood this feature targets it can time out and
      # RAISE. Mirroring the US-36.2 fair-share gate, an unmeasurable count must ADMIT
      # the batch (an innocent tenant must never get a generic HTTP 500), not block it.
      tenant = keyed_tenant()
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})

      # The fail-open path emits an alertable telemetry counter so "the valve is currently
      # admitting because it can't measure" is observable, not just a warning log.
      attach_failed_open(tenant.id)

      # Simulate a statement_timeout / transient DB error from the backlog count via the
      # DI seam (overrides the DataCase default that delegates to the real count). The
      # controller now rescues ONLY DB timeout/connection classes, so this must raise one
      # of them (a bare error would propagate and 500 by design).
      expect(Loopctl.MockBacklogCounter, :in_flight_ingestion_backlog, fn _tenant_id ->
        raise DBConnection.ConnectionError, "simulated statement_timeout"
      end)

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/knowledge/ingest/batch", %{
          items: [%{content: "Fail-open batch item", source_type: "newsletter"}]
        })

      # Fail OPEN: the batch is admitted (200) and the item enqueues, rather than 500.
      body = json_response(conn, 200)
      assert length(body["data"]) == 1
      assert Enum.all?(body["data"], fn r -> r["status"] == "queued" end)

      # ...and the fail-open telemetry fired with the bounded error_class tag.
      assert_receive {:backlog_failed_open, %{count: 1}, metadata}
      assert metadata.error_class == "connection"
    end

    test "a LocalGuc capture ABORT fails open too, under its OWN error_class",
         %{conn: conn} do
      # `LocalGuc`'s capture abort shares `DBConnection.ConnectionError` with the transient
      # pool faults the clause above fails open on, and is raised on PURPOSE — but it is
      # still an UNMEASURABLE count, and this gate exists so that never blocks an innocent,
      # under-threshold tenant. It therefore admits, and stays alertable through a distinct
      # `error_class` rather than through a 503 the tenant did nothing to earn.
      tenant = keyed_tenant()
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})

      attach_failed_open(tenant.id)

      # Raised with the real module's own message prefix, so the test binds to
      # `LocalGuc.capture_abort?/1`'s actual discriminator rather than a copy of it.
      expect(Loopctl.MockBacklogCounter, :in_flight_ingestion_backlog, fn _tenant_id ->
        raise DBConnection.ConnectionError,
              ~s(LocalGuc: could not capture ["statement_timeout"], which an enclosing ) <>
                "scope already overrode"
      end)

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/knowledge/ingest/batch", %{
          items: [%{content: "Capture abort item", source_type: "newsletter"}]
        })

      assert length(json_response(conn, 200)["data"]) == 1

      # Not "connection": an abort must be distinguishable from a pool blip on the dashboard.
      assert_receive {:backlog_failed_open, %{count: 1}, metadata}
      assert metadata.error_class == "guc_capture_abort"
    end

    test "a NON-timeout SQLSTATE is not reported as a timeout", %{conn: conn} do
      # The rescue catches EVERY `Postgrex.Error`, not only 57014, so a query bug in the
      # count path (a column renamed out from under `FairShare`) also fails open. It must
      # say so: labelling it "timeout" sends a triaging operator after the pool instead of
      # the query that broke.
      tenant = keyed_tenant()
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})

      attach_failed_open(tenant.id)

      expect(Loopctl.MockBacklogCounter, :in_flight_ingestion_backlog, fn _tenant_id ->
        raise %Postgrex.Error{
          postgres: %{code: :undefined_column, message: "column j.args does not exist"}
        }
      end)

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/knowledge/ingest/batch", %{
          items: [%{content: "Query-bug batch item", source_type: "newsletter"}]
        })

      assert length(json_response(conn, 200)["data"]) == 1

      assert_receive {:backlog_failed_open, %{count: 1}, metadata}
      assert metadata.error_class == "db_error"
    end

    test "a 57014 cancel IS reported as a timeout", %{conn: conn} do
      tenant = keyed_tenant()
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})

      attach_failed_open(tenant.id)

      expect(Loopctl.MockBacklogCounter, :in_flight_ingestion_backlog, fn _tenant_id ->
        raise %Postgrex.Error{
          postgres: %{code: :query_canceled, message: "canceling statement due to timeout"}
        }
      end)

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/knowledge/ingest/batch", %{
          items: [%{content: "Timeout batch item", source_type: "newsletter"}]
        })

      assert length(json_response(conn, 200)["data"]) == 1

      assert_receive {:backlog_failed_open, %{count: 1}, metadata}
      assert metadata.error_class == "timeout"
    end

    test "TC-36.3.7: a NON-DB error in the backlog count propagates (500), not fail-open",
         %{conn: conn} do
      # A programming error in the count path must NOT be silently swallowed into a
      # fleet-wide disabling of backpressure — it must surface (rescue is narrowed to DB
      # timeout/connection classes only).
      tenant = keyed_tenant()
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})

      expect(Loopctl.MockBacklogCounter, :in_flight_ingestion_backlog, fn _tenant_id ->
        raise ArgumentError, "simulated bug in count path"
      end)

      assert_raise ArgumentError, fn ->
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/knowledge/ingest/batch", %{
          items: [%{content: "Bug batch item", source_type: "newsletter"}]
        })
      end
    end
  end

  # --- GET /api/v1/knowledge/ingestion-jobs ---

  describe "GET /api/v1/knowledge/ingestion-jobs" do
    test "returns empty list for new tenant", %{conn: conn} do
      tenant = keyed_tenant()
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/ingestion-jobs")

      body = json_response(conn, 200)
      assert body["data"] == []
    end

    test "lists recent ingestion jobs", %{conn: conn} do
      tenant = keyed_tenant()
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})

      # Create an ingestion job (inline mode will execute immediately)
      conn
      |> auth_conn(raw_key)
      |> post(~p"/api/v1/knowledge/ingest", %{
        content: "Content for listing test",
        source_type: "newsletter"
      })

      conn =
        build_conn()
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/ingestion-jobs")

      body = json_response(conn, 200)
      assert is_list(body["data"])
      # In inline mode, the job may have already completed, but it should still be in the list
    end

    test "paginates with limit/offset + meta, and never caps or rejects (no hard 50)",
         %{conn: _conn} do
      tenant = keyed_tenant()
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})

      # Insert ingestion-job rows directly (deterministic — no inline-cascade or
      # timing dependence) with distinct inserted_at so paging order is stable.
      now = DateTime.utc_now()

      # Insert via AdminRepo: the count/list is routed through HeavyRead, which in
      # tests reads on AdminRepo (config/test.exs), so the setup rows must share that
      # sandbox transaction (same path every fixture uses). In prod both repos hit the
      # same DB, so Repo-written Oban jobs are visible to the heavy-read pool.
      for n <- 1..3 do
        %Oban.Job{
          worker: "Loopctl.Workers.ContentIngestionWorker",
          queue: "default",
          state: "completed",
          args: %{"tenant_id" => tenant.id, "source_type" => "newsletter", "n" => n},
          inserted_at: DateTime.add(now, -n, :second)
        }
        |> Loopctl.AdminRepo.insert!()
      end

      page1 =
        build_conn()
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/ingestion-jobs?limit=2")
        |> json_response(200)

      assert page1["meta"]["limit"] == 2
      assert page1["meta"]["offset"] == 0
      assert page1["meta"]["total_count"] == 3
      assert length(page1["data"]) == 2

      # Offset reaches the remainder — completeness, no hard cap.
      page2 =
        build_conn()
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/ingestion-jobs?limit=2&offset=2")
        |> json_response(200)

      assert length(page2["data"]) == 1

      # A huge limit is clamped to the max page size, never rejected (no hard
      # 50-row cap, no 400).
      big =
        build_conn()
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/ingestion-jobs?limit=5000")
        |> json_response(200)

      assert big["meta"]["limit"] <= 1000
    end

    test "agent role is rejected", %{conn: conn} do
      tenant = keyed_tenant()
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/ingestion-jobs")

      assert json_response(conn, 403)
    end

    test "unauthenticated returns 401", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/knowledge/ingestion-jobs")
      assert json_response(conn, 401)
    end
  end

  # --- Tenant isolation ---

  describe "tenant isolation" do
    # LOAD-BEARING SCOPING REGRESSION GUARD (US-34.6). The COUNT + list run on the
    # BYPASSRLS heavy-read pool via HeavyRead.one/all, and the base query's source is
    # the SCHEMALESS `from(j in "oban_jobs")` string table — so HeavyRead's structural
    # tenant-guard classifies it `:other` and auto-passes WITHOUT a tenant-equality
    # check, and `oban_jobs` carries no RLS policy. Tenant isolation therefore rests
    # ENTIRELY on the `args->>'tenant_id' = ^tenant_id` fragment in `list_ingestion_jobs/2`
    # (controller). This test (and its `total_count` sibling below) is the ONLY mechanism
    # that would catch a future edit weakening/parameterizing that fragment — keep it
    # inserting BOTH tenants' rows directly so it fails if the predicate ever leaks.
    test "tenant A cannot see tenant B's ingestion jobs", %{conn: conn} do
      tenant_a = keyed_tenant()
      tenant_b = keyed_tenant()
      {raw_key_a, _} = fixture(:api_key, %{tenant_id: tenant_a.id, role: :orchestrator})

      now = DateTime.utc_now()

      # Insert ingestion-job rows for BOTH tenants directly via AdminRepo. `testing:
      # :inline` (config/test.exs) runs the worker synchronously and persists NO
      # oban_jobs row, so a POST /ingest would leave the table empty and make this
      # assertion vacuous — insert deterministic rows on the same sandbox connection
      # HeavyRead reads from (AdminRepo in tests) instead.
      for {tenant, count} <- [{tenant_a, 2}, {tenant_b, 3}], n <- 1..count do
        %Oban.Job{
          worker: "Loopctl.Workers.ContentIngestionWorker",
          queue: "default",
          state: "completed",
          args: %{"tenant_id" => tenant.id, "source_type" => "newsletter", "n" => n},
          inserted_at: DateTime.add(now, -n, :second)
        }
        |> Loopctl.AdminRepo.insert!()
      end

      # Tenant A should not see ANY of tenant B's jobs, even though B's 3 rows exist
      # in the same table on the BYPASSRLS read connection.
      conn =
        conn
        |> auth_conn(raw_key_a)
        |> get(~p"/api/v1/knowledge/ingestion-jobs")

      body = json_response(conn, 200)

      tenant_b_jobs =
        Enum.filter(body["data"], fn job ->
          job["args"]["tenant_id"] == tenant_b.id
        end)

      assert tenant_b_jobs == []
      # A sees exactly its own 2 rows — not the 5 total on the connection.
      assert length(body["data"]) == 2
      assert body["meta"]["total_count"] == 2
    end

    test "total_count reflects ONLY the caller's tenant (deterministic direct-insert)",
         %{conn: conn} do
      tenant_a = keyed_tenant()
      tenant_b = keyed_tenant()
      {raw_key_a, _} = fixture(:api_key, %{tenant_id: tenant_a.id, role: :orchestrator})

      now = DateTime.utc_now()

      # 2 ingestion jobs for A, 3 for B — inserted directly for a deterministic count
      # (the HeavyRead-routed COUNT now runs on AdminRepo, which shares the sandbox
      # connection, so these rows are visible).
      for {tenant, count} <- [{tenant_a, 2}, {tenant_b, 3}], n <- 1..count do
        %Oban.Job{
          worker: "Loopctl.Workers.ContentIngestionWorker",
          queue: "default",
          state: "completed",
          args: %{"tenant_id" => tenant.id, "n" => n},
          inserted_at: DateTime.add(now, -n, :second)
        }
        |> Loopctl.AdminRepo.insert!()
      end

      body =
        conn
        |> auth_conn(raw_key_a)
        |> get(~p"/api/v1/knowledge/ingestion-jobs")
        |> json_response(200)

      # A sees ONLY its own 2 jobs — never the 5 total — proving the
      # `args->>'tenant_id' = caller` scoping holds through the HeavyRead-routed COUNT
      # and list (B's 3 rows are present in the same table but excluded).
      assert body["meta"]["total_count"] == 2
      assert length(body["data"]) == 2
    end
  end

  # --- Partial index backing the COUNT/list (AC-34.6.1) ---

  describe "oban_jobs_ingestion_tenant_idx partial index (AC-34.6.1)" do
    test "the composite partial expression index exists with the expected predicate" do
      %{rows: rows} =
        Loopctl.AdminRepo.query!(
          "SELECT indexdef FROM pg_indexes WHERE indexname = $1",
          ["oban_jobs_ingestion_tenant_idx"]
        )

      assert [[indexdef]] = rows,
             "expected oban_jobs_ingestion_tenant_idx to exist; migration did not run"

      # Indexes the args->>'tenant_id' expression, partial to the ingestion worker.
      assert indexdef =~ "args ->> 'tenant_id'"
      assert indexdef =~ "Loopctl.Workers.ContentIngestionWorker"

      # COMPOSITE shape (migration 20260713020000): the ORDER BY columns follow the
      # equality-matched tenant column so the ordered list is answered by an ordered
      # index scan (no full Sort). Pins the shape so a regression to the single-column
      # index — which would reintroduce the sort-heavy ordered list — fails here.
      assert indexdef =~ "inserted_at DESC"
      assert indexdef =~ "id DESC"
    end

    test "the planner chooses the partial index for the real ingestion COUNT predicate" do
      tenant = keyed_tenant()
      now = DateTime.utc_now()

      for n <- 1..5 do
        %Oban.Job{
          worker: "Loopctl.Workers.ContentIngestionWorker",
          queue: "default",
          state: "completed",
          args: %{"tenant_id" => tenant.id, "n" => n},
          inserted_at: DateTime.add(now, -n, :second)
        }
        |> Loopctl.AdminRepo.insert!()
      end

      # On the tiny sandbox dataset the planner prefers a seq scan purely on row count,
      # so an unqualified EXPLAIN can't assert plan shape (the AC-34.6.1 gap the raw
      # finding flagged). Disable seq scan for THIS transaction so the assertion tests
      # index ELIGIBILITY — does the partial index actually back the real predicate
      # (`worker = 'Loopctl.Workers.ContentIngestionWorker' AND args->>'tenant_id' = $1`)?
      # If the index were dropped or its expression/predicate no longer matched, the
      # planner would fall back to a seq scan even with it disabled and this would fail.
      Loopctl.AdminRepo.query!("SET LOCAL enable_seqscan = off")

      %{rows: rows} =
        Loopctl.AdminRepo.query!(
          """
          EXPLAIN (FORMAT TEXT)
          SELECT count(id) FROM oban_jobs
          WHERE worker = 'Loopctl.Workers.ContentIngestionWorker'
            AND args->>'tenant_id' = $1
          """,
          [tenant.id]
        )

      plan = rows |> List.flatten() |> Enum.join("\n")

      assert plan =~ "oban_jobs_ingestion_tenant_idx",
             "expected EXPLAIN to use the partial index, got:\n#{plan}"
    end

    test "the composite index answers the ordered list page without a full Sort" do
      tenant = keyed_tenant()
      now = DateTime.utc_now()

      for n <- 1..5 do
        %Oban.Job{
          worker: "Loopctl.Workers.ContentIngestionWorker",
          queue: "default",
          state: "completed",
          args: %{"tenant_id" => tenant.id, "n" => n},
          inserted_at: DateTime.add(now, -n, :second)
        }
        |> Loopctl.AdminRepo.insert!()
      end

      # Same eligibility technique as the COUNT test: on the tiny sandbox dataset the
      # planner would seq-scan + Sort purely on row count, so disable seq scan for THIS
      # transaction and assert the composite partial index oban_jobs_ingestion_tenant_idx
      # ((args->>'tenant_id'), inserted_at DESC, id DESC) can SUPPLY the ORDER BY — the
      # ordered page is an Index Scan feeding Limit with NO Sort node. If the index
      # regressed to single-column (no ordering columns), the planner would need a full
      # Sort even with seq scan disabled and this would fail — the regression guard for
      # US-34.6's "ordered list stays a range scan, not a sort" finding.
      Loopctl.AdminRepo.query!("SET LOCAL enable_seqscan = off")

      %{rows: rows} =
        Loopctl.AdminRepo.query!(
          """
          EXPLAIN (FORMAT TEXT)
          SELECT id, state, args, inserted_at, completed_at, errors FROM oban_jobs
          WHERE worker = 'Loopctl.Workers.ContentIngestionWorker'
            AND args->>'tenant_id' = $1
          ORDER BY inserted_at DESC, id DESC
          LIMIT 20 OFFSET 0
          """,
          [tenant.id]
        )

      plan = rows |> List.flatten() |> Enum.join("\n")

      assert plan =~ "oban_jobs_ingestion_tenant_idx",
             "expected the ordered list EXPLAIN to use the composite index, got:\n#{plan}"

      refute plan =~ "Sort",
             "expected the composite index to supply the ORDER BY (no Sort node), got:\n#{plan}"
    end
  end
end
