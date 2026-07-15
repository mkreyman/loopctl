defmodule Loopctl.Knowledge.EmbeddingClientTest do
  @moduledoc """
  The real tenant-scoped embedding client (mandatory BYO — #294 extended).

  Everywhere else the embedding client is swapped for `Loopctl.MockEmbeddingClient`;
  here we drive `Loopctl.Knowledge.EmbeddingClient` DIRECTLY through the
  `:embedding_req_plug` Req.Test plug so per-tenant key resolution + usage recording
  are exercised without any real OpenAI call.
  """
  use Loopctl.DataCase, async: true

  import ExUnit.CaptureLog
  import Mox

  alias Loopctl.Knowledge.EmbeddingClient
  alias Loopctl.Llm

  # Obviously-fake OpenAI-style key that does NOT use the real sk-/sk-proj- prefix
  # (so a secret scanner never flags it).
  defp set_embedding_key(tenant, key, model \\ "text-embedding-3-small") do
    {:ok, _} =
      Llm.upsert_settings(tenant.id, %{
        "embedding_api_key" => key,
        "embedding_model" => model
      })

    :ok
  end

  test "mandatory BYO: a keyless tenant gets {:error, :no_api_key} with NO provider call" do
    tenant = fixture(:tenant)
    test_pid = self()

    # If the client wrongly issued an HTTP request, this stub would fire.
    Req.Test.stub(EmbeddingClient, fn conn ->
      send(test_pid, :unexpected_http_call)
      Req.Test.json(conn, %{"data" => [%{"embedding" => [0.0]}]})
    end)

    assert {:error, :no_api_key} = EmbeddingClient.generate_embedding(tenant.id, "hello")
    refute_received :unexpected_http_call
  end

  test "US-37.1: empty admission bucket → {:error, :rate_limited_local}, NO provider call" do
    tenant = fixture(:tenant)
    test_pid = self()
    set_embedding_key(tenant, "test-openai-key-GATED")

    # Empty node-local bucket for the embedding provider.
    stub(Loopctl.MockRateLimiter, :check_rate, fn _bucket, _window, _limit -> {:deny, 0} end)

    # If the client wrongly issued an HTTP request despite the empty bucket, this
    # stub would fire.
    Req.Test.stub(EmbeddingClient, fn conn ->
      send(test_pid, :unexpected_http_call)
      Req.Test.json(conn, %{"data" => [%{"embedding" => [0.0]}]})
    end)

    assert {:error, :rate_limited_local} = EmbeddingClient.generate_embedding(tenant.id, "hello")
    refute_received :unexpected_http_call
  end

  test "with a key: uses the TENANT's Bearer key, returns the vector, records :embedding usage" do
    tenant = fixture(:tenant)
    test_pid = self()
    set_embedding_key(tenant, "test-openai-key-SUCCESS-777")

    Req.Test.stub(EmbeddingClient, fn conn ->
      send(test_pid, {:auth, Plug.Conn.get_req_header(conn, "authorization")})

      Req.Test.json(conn, %{
        "data" => [%{"embedding" => [0.1, 0.2, 0.3]}],
        "usage" => %{"prompt_tokens" => 11, "total_tokens" => 11}
      })
    end)

    assert {:ok, [0.1, 0.2, 0.3]} = EmbeddingClient.generate_embedding(tenant.id, "some text")

    # The tenant's OWN key rode the Authorization header.
    assert_received {:auth, ["Bearer test-openai-key-SUCCESS-777"]}

    # An :embedding usage event was recorded in the shared ledger.
    %{data: rows} = Llm.usage_summary(tenant.id, [])
    embedding = Enum.find(rows, &(&1.operation == :embedding))
    assert embedding.model == "text-embedding-3-small"
    assert embedding.input_tokens == 11
    assert embedding.output_tokens == 0
  end

  test "cross-tenant: tenant A's call uses A's key, never B's" do
    a = fixture(:tenant)
    b = fixture(:tenant)
    test_pid = self()

    set_embedding_key(a, "test-openai-key-AAAA")
    set_embedding_key(b, "test-openai-key-BBBB")

    Req.Test.stub(EmbeddingClient, fn conn ->
      send(test_pid, {:auth, Plug.Conn.get_req_header(conn, "authorization")})

      Req.Test.json(conn, %{
        "data" => [%{"embedding" => [1.0]}],
        "usage" => %{"prompt_tokens" => 1}
      })
    end)

    assert {:ok, [1.0]} = EmbeddingClient.generate_embedding(a.id, "x")
    assert_received {:auth, ["Bearer test-openai-key-AAAA"]}
    refute_received {:auth, ["Bearer test-openai-key-BBBB"]}
  end

  test "never logs the embedding api_key on the SUCCESS branch (review #14)" do
    tenant = fixture(:tenant)
    secret = "test-openai-key-SUCCESS-NEVERLOG-#{System.unique_integer([:positive])}"
    set_embedding_key(tenant, secret)

    Req.Test.stub(EmbeddingClient, fn conn ->
      Req.Test.json(conn, %{
        "data" => [%{"embedding" => [0.5, 0.5]}],
        "usage" => %{"prompt_tokens" => 3, "total_tokens" => 3}
      })
    end)

    log =
      capture_log(fn ->
        assert {:ok, [0.5, 0.5]} = EmbeddingClient.generate_embedding(tenant.id, "x")
      end)

    refute log =~ secret
  end

  test "never logs the embedding api_key on the error branch, and DROPS the body (review #3)" do
    tenant = fixture(:tenant)
    secret = "test-openai-key-NEVERLOG-#{System.unique_integer([:positive])}"
    set_embedding_key(tenant, secret)

    # A realistic OpenAI 401 body that echoes a masked key fragment — it must never
    # reach the returned error term (which becomes an Oban error) nor the logs.
    masked = "test-openai-...ZXY9"

    Req.Test.stub(EmbeddingClient, fn conn ->
      conn
      |> Plug.Conn.put_status(401)
      |> Req.Test.json(%{"error" => %{"message" => "Incorrect API key provided: #{masked}"}})
    end)

    log =
      capture_log(fn ->
        # Sanitized: value-free {:api_error, 401, :provider_error} — no body.
        assert {:error, {:api_error, 401, :provider_error}} =
                 EmbeddingClient.generate_embedding(tenant.id, "x")
      end)

    refute log =~ secret
    refute log =~ masked
  end

  # --- US-37.3 (AC-37.3.2): parse the provider Retry-After on a throttle response ---

  test "a 429 with a Retry-After header surfaces the throttle 4-tuple (parsed seconds)" do
    tenant = fixture(:tenant)
    set_embedding_key(tenant, "test-openai-key-THROTTLED")

    Req.Test.stub(EmbeddingClient, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("retry-after", "30")
      |> Plug.Conn.put_status(429)
      |> Req.Test.json(%{"error" => %{"message" => "Rate limit reached"}})
    end)

    assert {:error, {:api_error, 429, :provider_error, 30}} =
             EmbeddingClient.generate_embedding(tenant.id, "x")
  end

  test "a 429 WITHOUT a Retry-After header keeps the legacy value-free 3-tuple" do
    tenant = fixture(:tenant)
    set_embedding_key(tenant, "test-openai-key-THROTTLED-NOHDR")

    Req.Test.stub(EmbeddingClient, fn conn ->
      conn
      |> Plug.Conn.put_status(429)
      |> Req.Test.json(%{"error" => %{"message" => "Rate limit reached"}})
    end)

    assert {:error, {:api_error, 429, :provider_error}} =
             EmbeddingClient.generate_embedding(tenant.id, "x")
  end

  test "a 503 with a Retry-After HTTP-date surfaces the throttle 4-tuple (~seconds out)" do
    tenant = fixture(:tenant)
    set_embedding_key(tenant, "test-openai-key-UNAVAILABLE")

    date =
      DateTime.utc_now()
      |> DateTime.add(30, :second)
      |> Calendar.strftime("%a, %d %b %Y %H:%M:%S GMT")

    Req.Test.stub(EmbeddingClient, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("retry-after", date)
      |> Plug.Conn.put_status(503)
      |> Req.Test.json(%{"error" => %{"message" => "Service unavailable"}})
    end)

    assert {:error, {:api_error, 503, :provider_error, seconds}} =
             EmbeddingClient.generate_embedding(tenant.id, "x")

    assert is_integer(seconds) and seconds >= 25 and seconds <= 30
  end

  # --- US-37.4 (AC-37.4.1): batch path — array in, map back BY response index ---

  test "TC-37.4.1: batch sends input as an array and maps each vector BY response index" do
    tenant = fixture(:tenant)
    test_pid = self()
    set_embedding_key(tenant, "test-openai-key-BATCH")

    texts = ["alpha", "beta", "gamma"]

    # SHUFFLED indices + DISTINCT vectors so a by-POSITION assumption would fail:
    # index 0 -> [1.0], 1 -> [2.0], 2 -> [3.0], returned out of order.
    Req.Test.stub(EmbeddingClient, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:req_body, JSON.decode!(body)})

      Req.Test.json(conn, %{
        "data" => [
          %{"index" => 2, "embedding" => [3.0]},
          %{"index" => 0, "embedding" => [1.0]},
          %{"index" => 1, "embedding" => [2.0]}
        ],
        "usage" => %{"prompt_tokens" => 9, "total_tokens" => 9}
      })
    end)

    assert {:ok, [[1.0], [2.0], [3.0]]} = EmbeddingClient.generate_embeddings(tenant.id, texts)

    # The request body carried `input` as an ARRAY of all three texts (not one call each).
    assert_received {:req_body, %{"input" => ^texts}}
  end

  test "batch: empty input list returns {:ok, []} with NO provider call" do
    tenant = fixture(:tenant)
    test_pid = self()
    set_embedding_key(tenant, "test-openai-key-EMPTY")

    Req.Test.stub(EmbeddingClient, fn conn ->
      send(test_pid, :unexpected_http_call)
      Req.Test.json(conn, %{"data" => []})
    end)

    assert {:ok, []} = EmbeddingClient.generate_embeddings(tenant.id, [])
    refute_received :unexpected_http_call
  end

  test "batch: mandatory BYO keyless tenant → {:error, :no_api_key}, NO provider call" do
    tenant = fixture(:tenant)
    test_pid = self()

    Req.Test.stub(EmbeddingClient, fn conn ->
      send(test_pid, :unexpected_http_call)
      Req.Test.json(conn, %{"data" => [%{"index" => 0, "embedding" => [0.0]}]})
    end)

    assert {:error, :no_api_key} = EmbeddingClient.generate_embeddings(tenant.id, ["a", "b"])
    refute_received :unexpected_http_call
  end

  test "TC-37.4.4: a SHORT data array (missing an index) fails the WHOLE batch, no partial" do
    tenant = fixture(:tenant)
    set_embedding_key(tenant, "test-openai-key-SHORT")

    # 3 inputs, but the provider returns only 2 vectors (index 2 missing).
    Req.Test.stub(EmbeddingClient, fn conn ->
      Req.Test.json(conn, %{
        "data" => [
          %{"index" => 0, "embedding" => [1.0]},
          %{"index" => 1, "embedding" => [2.0]}
        ]
      })
    end)

    assert {:error, {:embedding_index_mismatch, 3, 2}} =
             EmbeddingClient.generate_embeddings(tenant.id, ["a", "b", "c"])
  end

  test "batch: one admission token per batch — an empty bucket fast-fails :rate_limited_local" do
    tenant = fixture(:tenant)
    test_pid = self()
    set_embedding_key(tenant, "test-openai-key-BATCH-GATED")

    stub(Loopctl.MockRateLimiter, :check_rate, fn _bucket, _window, _limit -> {:deny, 0} end)

    Req.Test.stub(EmbeddingClient, fn conn ->
      send(test_pid, :unexpected_http_call)
      Req.Test.json(conn, %{"data" => [%{"index" => 0, "embedding" => [0.0]}]})
    end)

    assert {:error, :rate_limited_local} =
             EmbeddingClient.generate_embeddings(tenant.id, ["a", "b"])

    refute_received :unexpected_http_call
  end

  test "batch: records a single :embedding usage event for the whole array" do
    tenant = fixture(:tenant)
    set_embedding_key(tenant, "test-openai-key-BATCH-USAGE")

    Req.Test.stub(EmbeddingClient, fn conn ->
      Req.Test.json(conn, %{
        "data" => [
          %{"index" => 0, "embedding" => [0.1]},
          %{"index" => 1, "embedding" => [0.2]}
        ],
        "usage" => %{"prompt_tokens" => 20, "total_tokens" => 20}
      })
    end)

    assert {:ok, [[0.1], [0.2]]} = EmbeddingClient.generate_embeddings(tenant.id, ["a", "b"])

    %{data: rows} = Llm.usage_summary(tenant.id, [])
    embedding = Enum.find(rows, &(&1.operation == :embedding))
    assert embedding.input_tokens == 20
  end
end
