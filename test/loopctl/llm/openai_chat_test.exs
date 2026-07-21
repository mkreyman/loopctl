defmodule Loopctl.Llm.OpenAiChatTest do
  @moduledoc """
  Contract PARITY between `Loopctl.Llm.OpenAiChat` and `Loopctl.Llm.Anthropic`
  (US-41.3, AC-41.3.1) plus the usage representation AC-41.3.6 requires, exercised
  end-to-end through the `:openai_chat_req_plug` `Req.Test` seam (no real server).
  """
  use Loopctl.DataCase, async: true

  import ExUnit.CaptureLog

  alias Loopctl.Llm
  alias Loopctl.Llm.Anthropic
  alias Loopctl.Llm.OpenAiChat

  @base_url "https://llm.example.com/v1"

  defp openai_tenant(attrs \\ %{}) do
    tenant = fixture(:tenant)

    {:ok, _} =
      Llm.upsert_settings(
        tenant.id,
        Map.merge(
          %{
            "chat_provider" => "openai_compatible",
            "chat_base_url" => @base_url,
            "chat_api_key" => "local-key-#{System.unique_integer([:positive])}",
            "extraction_model" => "llama-3.1-8b-instruct"
          },
          attrs
        )
      )

    tenant
  end

  defp body_fun do
    fn _model ->
      %{
        max_tokens: 128,
        temperature: 0,
        system: "SYSTEM PROMPT",
        messages: [%{role: "user", content: "hello"}]
      }
    end
  end

  defp stub_completion(text, usage) do
    Req.Test.stub(Loopctl.Llm.OpenAiChat, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(self(), {:openai_request, conn.request_path, conn.req_headers, JSON.decode!(raw)})

      body = %{"choices" => [%{"message" => %{"role" => "assistant", "content" => text}}]}
      body = if usage, do: Map.put(body, "usage", usage), else: body

      Req.Test.json(conn, body)
    end)
  end

  describe "message/5 — happy path" do
    test "posts /chat/completions with a Bearer key, the system prompt as a message, and returns text" do
      tenant = openai_tenant()

      stub_completion("ANSWER", %{"prompt_tokens" => 11, "completion_tokens" => 7})

      assert {:ok, "ANSWER"} = OpenAiChat.message(tenant.id, :extraction, body_fun())

      assert_received {:openai_request, path, headers, req_body}
      assert path == "/v1/chat/completions"
      assert {"authorization", "Bearer " <> _} = List.keyfind(headers, "authorization", 0)

      # The Anthropic-shaped body_fun result is translated INSIDE the client
      # (technical note 2): the system prompt becomes the first system message.
      assert req_body["model"] == "llama-3.1-8b-instruct"

      assert [%{"role" => "system", "content" => "SYSTEM PROMPT"}, %{"role" => "user"} | _] =
               req_body["messages"]

      assert req_body["max_tokens"] == 128
      assert req_body["temperature"] == 0
    end

    test "records a provider-attributed usage row (AC-41.3.6)" do
      tenant = openai_tenant()
      stub_completion("ANSWER", %{"prompt_tokens" => 11, "completion_tokens" => 7})

      assert {:ok, "ANSWER"} = OpenAiChat.message(tenant.id, :extraction, body_fun())

      %{data: [row]} = Llm.usage_summary(tenant.id, [])
      assert row.operation == :extraction
      assert row.model == "llama-3.1-8b-instruct"
      assert row.provider == "openai_compatible"
      assert row.input_tokens == 11
      assert row.output_tokens == 7
    end

    test "a local endpoint reporting NO usage block still records a ZERO-token row" do
      # AC-41.3.6: "a zero-cost provider is fine; a silently missing usage row is not".
      tenant = openai_tenant()
      stub_completion("ANSWER", nil)

      assert {:ok, "ANSWER"} = OpenAiChat.message(tenant.id, :extraction, body_fun())

      %{data: [row]} = Llm.usage_summary(tenant.id, [])
      assert row.provider == "openai_compatible"
      assert row.input_tokens == 0
      assert row.output_tokens == 0
      assert row.model == "llama-3.1-8b-instruct"
    end
  end

  describe "error parity with Loopctl.Llm.Anthropic" do
    test "a 4xx is sanitized (no provider body) and records no usage" do
      tenant = openai_tenant()

      Req.Test.stub(Loopctl.Llm.OpenAiChat, fn conn ->
        conn
        |> Plug.Conn.put_status(401)
        |> Req.Test.json(%{"error" => "Incorrect API key provided: sk-...ZXY"})
      end)

      log =
        capture_log(fn ->
          assert {:error, {:api_error, 401, :provider_error}} =
                   OpenAiChat.message(tenant.id, :extraction, body_fun())
        end)

      refute log =~ "sk-...ZXY"
      assert %{data: []} = Llm.usage_summary(tenant.id, [])
    end

    test "a 429 carries the parsed Retry-After in the sanitized 4-tuple" do
      tenant = openai_tenant()

      Req.Test.stub(Loopctl.Llm.OpenAiChat, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("retry-after", "17")
        |> Plug.Conn.put_status(429)
        |> Req.Test.json(%{"error" => "slow down"})
      end)

      capture_log(fn ->
        assert {:error, {:api_error, 429, :provider_error, 17}} =
                 OpenAiChat.message(tenant.id, :extraction, body_fun())
      end)
    end

    test "a transport error is returned as {:request_failed, reason} and never logs the key" do
      tenant = openai_tenant()

      Req.Test.stub(Loopctl.Llm.OpenAiChat, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      log =
        capture_log(fn ->
          assert {:error, {:request_failed, _}} =
                   OpenAiChat.message(tenant.id, :extraction, body_fun())
        end)

      refute log =~ "local-key-"
    end

    test "a 200 whose body is not an OpenAI envelope is a legible shape error, not a raw body" do
      tenant = openai_tenant()

      Req.Test.stub(Loopctl.Llm.OpenAiChat, fn conn ->
        Req.Test.json(conn, %{"result" => "sk-leaky-fragment"})
      end)

      capture_log(fn ->
        assert {:error, {:invalid_response_shape, details}} =
                 OpenAiChat.message(tenant.id, :extraction, body_fun())

        assert details.reason == :missing_choices
        assert details.endpoint == "#{@base_url}/chat/completions"
        assert details.model == "llama-3.1-8b-instruct"
        refute inspect(details) =~ "sk-leaky-fragment"
      end)

      # AC-41.3.6: the endpoint ANSWERED 200, so tokens were spent even though the
      # body is unusable — a silently missing usage row is not acceptable.
      assert %{data: [row]} = Llm.usage_summary(tenant.id, [])
      assert row.provider == "openai_compatible"
      assert row.model == "llama-3.1-8b-instruct"
      assert row.input_tokens == 0
      assert row.output_tokens == 0
    end

    test "a 200 with a choices envelope but no text content records the usage it reports" do
      tenant = openai_tenant()

      Req.Test.stub(Loopctl.Llm.OpenAiChat, fn conn ->
        Req.Test.json(conn, %{
          "choices" => [%{"message" => %{"role" => "assistant", "refusal" => "no"}}],
          "usage" => %{"prompt_tokens" => 31, "completion_tokens" => 2}
        })
      end)

      capture_log(fn ->
        assert {:error, {:invalid_response_shape, details}} =
                 OpenAiChat.message(tenant.id, :extraction, body_fun())

        assert details.reason == :non_text_content
      end)

      assert %{data: [row]} = Llm.usage_summary(tenant.id, [])
      assert row.provider == "openai_compatible"
      assert row.input_tokens == 31
      assert row.output_tokens == 2
    end
  end

  describe "SSRF (chat_base_url is TENANT-WRITABLE)" do
    test "a private-range endpoint is refused BEFORE the request is built" do
      # `chat_base_url` is tenant data, so this client owns the SSRF denylist on the
      # default (non-local_only) egress path. Without it a role :user key could make
      # loopctl POST tenant content at the cloud metadata endpoint.
      tenant = openai_tenant(%{"chat_base_url" => "http://169.254.169.254/v1"})

      # No Req.Test stub is installed: reaching the transport at all would raise.
      capture_log(fn ->
        assert {:error, {:egress_blocked, details}} =
                 OpenAiChat.message(tenant.id, :extraction, body_fun())

        assert details.verdict == :denylisted
      end)
    end

    test "a public vendor endpoint on the SAME default path is untouched" do
      # The refusal must be scoped to the denylist, never a new failure mode for
      # ordinary hosts (AC-41.4.12's default-off promise).
      tenant = openai_tenant()
      stub_completion("ANSWER", nil)

      assert {:ok, "ANSWER"} = OpenAiChat.message(tenant.id, :extraction, body_fun())
    end
  end

  describe "keyless endpoints (US-41.3 review)" do
    test "a tenant with no chat key resolves and posts with NO authorization header" do
      tenant = fixture(:tenant)

      {:ok, _} =
        Llm.upsert_settings(tenant.id, %{
          "chat_provider" => "openai_compatible",
          "chat_base_url" => @base_url,
          "extraction_model" => "llama-3.1-8b-instruct"
        })

      stub_completion("ANSWER", nil)

      assert {:ok, "ANSWER"} = OpenAiChat.message(tenant.id, :extraction, body_fun())

      assert_received {:openai_request, _path, headers, _body}
      refute List.keyfind(headers, "authorization", 0)
    end
  end

  describe "model resolution is provider-aware (US-41.3 review)" do
    test "an unset per-operation model follows the tenant's chat model, NOT the Anthropic default" do
      tenant = openai_tenant()

      # `@default_model` is "claude-haiku-…" — posting that to a local server would
      # fail every call while a probe of some other model reported green.
      assert {:ok, %{model: "llama-3.1-8b-instruct"}} = Llm.resolve(tenant.id, :classification)
      assert {:ok, %{model: "llama-3.1-8b-instruct"}} = Llm.resolve(tenant.id, :merge)
    end
  end

  describe "credential isolation" do
    test "a tenant on the Anthropic default is REFUSED, never handed its Anthropic key" do
      tenant = fixture(:tenant)
      {:ok, _} = Llm.upsert_settings(tenant.id, %{"api_key" => "sk-ant-must-not-travel"})

      assert {:error, :provider_mismatch} =
               OpenAiChat.message(tenant.id, :extraction, body_fun())
    end

    test "a tenant with no key at all gets {:error, :no_api_key}" do
      tenant = fixture(:tenant)
      assert {:error, :no_api_key} = OpenAiChat.message(tenant.id, :extraction, body_fun())
    end

    test "resolve_target/2 returns the endpoint and never the Anthropic key" do
      tenant = openai_tenant()

      assert {:ok, target} = OpenAiChat.resolve_target(tenant.id, :extraction)
      assert target.endpoint == "#{@base_url}/chat/completions"
      assert target.base_url == @base_url
      assert String.starts_with?(target.api_key, "local-key-")
    end
  end

  describe "admission (AC-41.3.5)" do
    test "an empty bucket short-circuits BEFORE any request is issued" do
      tenant = openai_tenant()

      Mox.stub(Loopctl.MockRateLimiter, :check_rate, fn _bucket, _window, _limit ->
        {:deny, 0}
      end)

      # No Req.Test stub is installed: if the client reached the transport at all,
      # Req.Test would raise "no stub found" instead of returning this term.
      assert {:error, :rate_limited_local} =
               OpenAiChat.message(tenant.id, :extraction, body_fun())
    end
  end

  describe "tenant isolation" do
    test "tenant A's chat endpoint + key never resolve for tenant B" do
      a = openai_tenant(%{"chat_base_url" => "https://a.example.com/v1"})
      b = fixture(:tenant)

      assert {:ok, %{base_url: "https://a.example.com/v1"}} =
               OpenAiChat.resolve_target(a.id, :extraction)

      assert {:error, :no_api_key} = OpenAiChat.resolve_target(b.id, :extraction)
      assert Llm.chat_base_url(b.id) == Anthropic.base_url()
    end
  end
end
