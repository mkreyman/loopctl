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
end
