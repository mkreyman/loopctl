defmodule LoopctlWeb.LlmConfigControllerTest do
  use LoopctlWeb.ConnCase, async: true

  alias Loopctl.Llm

  defp auth_conn(conn, raw_key), do: put_req_header(conn, "authorization", "Bearer #{raw_key}")

  describe "secret redaction from Phoenix request-param logs (review #5, #10)" do
    # The Phoenix "Parameters:" request-log line redacts values via
    # `Phoenix.Logger.filter_values/1`, which applies the `:filter_parameters` config
    # (#5). We test that exact function — it IS the param-log redaction path — rather
    # than a capture_log integration test, because the param line is emitted at :debug
    # while config/test.exs pins the primary Logger level to :warning, and neither
    # capture_log's `:level` opt nor `Logger.put_process_level/2` lowers the primary
    # level (verified empirically), so a capture-based test can't emit that line in an
    # async test without the forbidden global `Logger.configure/1`. This assertion is
    # NON-VACUOUS: removing the `config :phoenix, :filter_parameters` entry reverts
    # the api_key to the default (unfiltered) behaviour and fails the first assert.
    test "filter_parameters redacts api_key (the exact param-log redaction)" do
      secret = "test-anthropic-LEAKCHECK-#{System.unique_integer([:positive])}"

      filtered = Phoenix.Logger.filter_values(%{"api_key" => secret, "keep_me" => "visible"})

      assert filtered["api_key"] == "[FILTERED]"
      # A non-secret param is untouched (proves we didn't over-filter / vacuously pass).
      assert filtered["keep_me"] == "visible"
      refute inspect(filtered) =~ secret
    end
  end

  describe "PATCH /api/v1/tenants/me/llm-config" do
    test "sets the api_key + models (role user); response never leaks the key", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      body =
        conn
        |> auth_conn(raw_key)
        |> patch(~p"/api/v1/tenants/me/llm-config", %{
          api_key: "test-anthropic-controller-key",
          extraction_model: "claude-opus-4-1",
          classification_model: "claude-sonnet-4-5"
        })
        |> json_response(200)

      assert body["has_api_key"] == true
      assert body["api_key_hint"] == "...-key"
      assert body["extraction_model"] == "claude-opus-4-1"
      assert body["classification_model"] == "claude-sonnet-4-5"
      refute Map.has_key?(body, "api_key")
      refute inspect(body) =~ "test-anthropic-controller-key"

      # Persisted + resolvable.
      assert {:ok, %{api_key: "test-anthropic-controller-key", model: "claude-opus-4-1"}} =
               Llm.resolve(tenant.id, :extraction)
    end

    test "a lower role (orchestrator) is rejected with 403", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})

      conn =
        conn
        |> auth_conn(raw_key)
        |> patch(~p"/api/v1/tenants/me/llm-config", %{api_key: "test-anthropic-x"})

      assert json_response(conn, 403)
      # Nothing was stored.
      refute Llm.has_api_key?(tenant.id)
    end

    test "422 on an invalid model id", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      conn =
        conn
        |> auth_conn(raw_key)
        |> patch(~p"/api/v1/tenants/me/llm-config", %{extraction_model: "bad model!"})

      assert json_response(conn, 422)
    end
  end

  describe "GET /api/v1/tenants/me/llm-config" do
    test "returns models + has_api_key + masked hint, never the key", %{conn: conn} do
      tenant = fixture(:tenant)
      {:ok, _} = Llm.upsert_settings(tenant.id, %{"api_key" => "test-anthropic-abcd1234"})
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      body =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/tenants/me/llm-config")
        |> json_response(200)

      assert body["has_api_key"] == true
      assert body["api_key_hint"] == "...1234"
      refute inspect(body) =~ "test-anthropic-abcd1234"
    end

    test "reports has_api_key false when unconfigured", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      body =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/tenants/me/llm-config")
        |> json_response(200)

      assert body["has_api_key"] == false
      assert is_nil(body["api_key_hint"])
    end
  end

  describe "tenant isolation" do
    test "tenant A only sees its own config, never tenant B's key", %{conn: conn} do
      a = fixture(:tenant)
      b = fixture(:tenant)
      {:ok, _} = Llm.upsert_settings(a.id, %{"api_key" => "test-anthropic-aaaa1111"})
      {:ok, _} = Llm.upsert_settings(b.id, %{"api_key" => "test-anthropic-bbbb2222"})

      {raw_key_a, _} = fixture(:api_key, %{tenant_id: a.id, role: :user})

      body =
        conn
        |> auth_conn(raw_key_a)
        |> get(~p"/api/v1/tenants/me/llm-config")
        |> json_response(200)

      assert body["api_key_hint"] == "...1111"
      refute inspect(body) =~ "bbbb2222"
    end
  end

  # --- BYO embeddings (#294 extended): the SEPARATE OpenAI embedding key/model ---

  describe "embedding config via PATCH/GET" do
    test "filter_parameters redacts embedding_api_key (the exact param-log redaction)" do
      secret = "test-openai-LEAKCHECK-#{System.unique_integer([:positive])}"

      filtered =
        Phoenix.Logger.filter_values(%{"embedding_api_key" => secret, "keep_me" => "visible"})

      # "embedding_api_key" contains the "api_key" discard-substring, so it is filtered.
      assert filtered["embedding_api_key"] == "[FILTERED]"
      assert filtered["keep_me"] == "visible"
      refute inspect(filtered) =~ secret
    end

    test "PATCH sets the embedding key + model (role user); response never leaks the key",
         %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      body =
        conn
        |> auth_conn(raw_key)
        |> patch(~p"/api/v1/tenants/me/llm-config", %{
          embedding_api_key: "test-openai-controller-key",
          embedding_model: "text-embedding-3-large"
        })
        |> json_response(200)

      assert body["has_embedding_key"] == true
      assert body["embedding_api_key_hint"] == "...-key"
      assert body["embedding_model"] == "text-embedding-3-large"
      refute Map.has_key?(body, "embedding_api_key")
      refute inspect(body) =~ "test-openai-controller-key"

      assert {:ok, %{api_key: "test-openai-controller-key", model: "text-embedding-3-large"}} =
               Llm.resolve(tenant.id, :embedding)
    end

    test "a lower role (agent) is rejected with 403 and stores nothing", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      conn =
        conn
        |> auth_conn(raw_key)
        |> patch(~p"/api/v1/tenants/me/llm-config", %{embedding_api_key: "test-openai-x"})

      assert json_response(conn, 403)
      refute Llm.has_embedding_key?(tenant.id)
    end

    test "GET reports has_embedding_key + hint, never the embedding key", %{conn: conn} do
      tenant = fixture(:tenant)
      {:ok, _} = Llm.upsert_settings(tenant.id, %{"embedding_api_key" => "test-openai-wxyz5678"})
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      body =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/tenants/me/llm-config")
        |> json_response(200)

      assert body["has_embedding_key"] == true
      assert body["embedding_api_key_hint"] == "...5678"
      refute inspect(body) =~ "test-openai-wxyz5678"
    end

    test "tenant A never sees tenant B's embedding key", %{conn: conn} do
      a = fixture(:tenant)
      b = fixture(:tenant)
      {:ok, _} = Llm.upsert_settings(a.id, %{"embedding_api_key" => "test-openai-aaaa1111"})
      {:ok, _} = Llm.upsert_settings(b.id, %{"embedding_api_key" => "test-openai-bbbb2222"})

      {raw_key_a, _} = fixture(:api_key, %{tenant_id: a.id, role: :user})

      body =
        conn
        |> auth_conn(raw_key_a)
        |> get(~p"/api/v1/tenants/me/llm-config")
        |> json_response(200)

      assert body["embedding_api_key_hint"] == "...1111"
      refute inspect(body) =~ "bbbb2222"
    end
  end
end
