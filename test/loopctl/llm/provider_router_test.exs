defmodule Loopctl.Llm.ProviderRouterTest do
  @moduledoc """
  TC-41.3.1 — tenant-scoped provider selection through the UNCHANGED DI seam
  (US-41.3, AC-41.3.2).

  Two tenants on ONE node resolve DIFFERENT siblings through the SAME configured
  module, with no cross-contamination of client or credentials. The `config/test.exs`
  Mox mappings are asserted to still be the seam config points at — no test in this
  repo uses `Application.put_env`, and none needed to change for this story.
  """
  use Loopctl.DataCase, async: true

  alias Loopctl.Knowledge.ClassifierRouter
  alias Loopctl.Knowledge.ContentExtractorRouter
  alias Loopctl.Knowledge.ExtractorRouter
  alias Loopctl.Knowledge.MergeSynthesizerRouter
  alias Loopctl.Llm
  alias Loopctl.Llm.Anthropic
  alias Loopctl.Memory.Promoter.LLMRouter

  @openai_base "https://local.example.com/v1"

  defp anthropic_tenant do
    tenant = fixture(:tenant)
    {:ok, _} = Llm.upsert_settings(tenant.id, %{"api_key" => "sk-ant-tenant-a-secret"})
    tenant
  end

  defp openai_tenant do
    tenant = fixture(:tenant)

    {:ok, _} =
      Llm.upsert_settings(tenant.id, %{
        "chat_provider" => "openai_compatible",
        "chat_base_url" => @openai_base,
        "chat_api_key" => "local-tenant-b-secret",
        "extraction_model" => "llama-3.1-8b-instruct"
      })

    tenant
  end

  describe "the DI seam is preserved, not replaced" do
    test "config/test.exs still maps every behaviour to its Mox mock" do
      # The routers are the PRODUCTION defaults; in test the same
      # `Application.get_env`/`compile_env` resolution point still yields the mock,
      # so no existing test changed and none needs Application.put_env.
      assert Application.get_env(:loopctl, :content_extractor) == Loopctl.MockContentExtractor
      assert Application.get_env(:loopctl, :knowledge_extractor) == Loopctl.MockExtractor
      assert Application.get_env(:loopctl, :category_classifier) == Loopctl.MockCategoryClassifier
      assert Application.get_env(:loopctl, :merge_synthesizer) == Loopctl.MockMergeSynthesizer
      assert Application.get_env(:loopctl, :promoter_llm) == Loopctl.MockPromoterLLM
    end

    test "every router implements the behaviour the seam is typed against" do
      for {router, behaviour} <- [
            {ContentExtractorRouter, Loopctl.Knowledge.ContentExtractorBehaviour},
            {ExtractorRouter, Loopctl.Knowledge.ExtractorBehaviour},
            {ClassifierRouter, Loopctl.Knowledge.ClassifierBehaviour},
            {MergeSynthesizerRouter, Loopctl.Knowledge.MergeSynthesizerBehaviour},
            {LLMRouter, Loopctl.Memory.Promoter.LLMBehaviour}
          ] do
        assert behaviour in (router.module_info(:attributes)[:behaviour] || [])
      end
    end
  end

  describe "two tenants, one node, different siblings" do
    test "sibling_for/1 differs per tenant across ALL five routers" do
      a = anthropic_tenant()
      b = openai_tenant()

      assert ContentExtractorRouter.sibling_for(a.id) ==
               Loopctl.Knowledge.ClaudeContentExtractor

      assert ContentExtractorRouter.sibling_for(b.id) ==
               Loopctl.Knowledge.OpenAiContentExtractor

      assert ExtractorRouter.sibling_for(a.id) == Loopctl.Knowledge.LlmExtractor
      assert ExtractorRouter.sibling_for(b.id) == Loopctl.Knowledge.OpenAiExtractor

      assert ClassifierRouter.sibling_for(a.id) == Loopctl.Knowledge.ClaudeCategoryClassifier
      assert ClassifierRouter.sibling_for(b.id) == Loopctl.Knowledge.OpenAiCategoryClassifier

      assert MergeSynthesizerRouter.sibling_for(a.id) == Loopctl.Knowledge.ClaudeMergeSynthesizer
      assert MergeSynthesizerRouter.sibling_for(b.id) == Loopctl.Knowledge.OpenAiMergeSynthesizer

      assert LLMRouter.sibling_for(a.id) == Loopctl.Memory.Promoter.DefaultLLM
      assert LLMRouter.sibling_for(b.id) == Loopctl.Memory.Promoter.OpenAiLLM
    end

    test "an extraction for each tenant hits its OWN provider with its OWN credential" do
      a = anthropic_tenant()
      b = openai_tenant()

      test_pid = self()

      Req.Test.stub(Anthropic, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:hit, :anthropic, conn.req_headers, JSON.decode!(raw)})

        Req.Test.json(conn, %{
          "content" => [
            %{
              "type" => "text",
              "text" =>
                JSON.encode!([%{title: "A1", body: "B", category: "pattern", tags: ["x"]}])
            }
          ],
          "usage" => %{"input_tokens" => 3, "output_tokens" => 2}
        })
      end)

      Req.Test.stub(Loopctl.Llm.OpenAiChat, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:hit, :openai, conn.req_headers, JSON.decode!(raw)})

        Req.Test.json(conn, %{
          "choices" => [
            %{
              "message" => %{
                "content" =>
                  JSON.encode!([%{title: "B1", body: "B", category: "pattern", tags: ["y"]}])
              }
            }
          ],
          "usage" => %{"prompt_tokens" => 5, "completion_tokens" => 4}
        })
      end)

      assert {:ok, [%{title: "A1"}]} =
               ContentExtractorRouter.extract_from_content(a.id, "raw", source_type: "newsletter")

      assert {:ok, [%{title: "B1"}]} =
               ContentExtractorRouter.extract_from_content(b.id, "raw", source_type: "newsletter")

      assert_received {:hit, :anthropic, anthropic_headers, _}
      assert_received {:hit, :openai, openai_headers, _}

      # No cross-contamination: each request carried ONLY its own provider's
      # credential, in that provider's own header.
      assert {"x-api-key", "sk-ant-tenant-a-secret"} in anthropic_headers
      refute Enum.any?(anthropic_headers, fn {k, _} -> k == "authorization" end)

      assert {"authorization", "Bearer local-tenant-b-secret"} in openai_headers
      refute Enum.any?(openai_headers, fn {k, _} -> k == "x-api-key" end)
    end

    test "usage rows are provider-attributed per tenant and tenant-isolated" do
      a = anthropic_tenant()
      b = openai_tenant()

      Req.Test.stub(Anthropic, fn conn ->
        Req.Test.json(conn, %{
          "content" => [%{"type" => "text", "text" => JSON.encode!([])}],
          "usage" => %{"input_tokens" => 3, "output_tokens" => 2}
        })
      end)

      Req.Test.stub(Loopctl.Llm.OpenAiChat, fn conn ->
        Req.Test.json(conn, %{
          "choices" => [%{"message" => %{"content" => JSON.encode!([])}}],
          "usage" => %{"prompt_tokens" => 5, "completion_tokens" => 4}
        })
      end)

      assert {:ok, []} = ContentExtractorRouter.extract_from_content(a.id, "raw")
      assert {:ok, []} = ContentExtractorRouter.extract_from_content(b.id, "raw")

      %{data: [row_a]} = Llm.usage_summary(a.id, [])
      %{data: [row_b]} = Llm.usage_summary(b.id, [])

      assert row_a.provider == "anthropic"
      assert row_b.provider == "openai_compatible"
    end

    # US-41.3 review: `KnowledgeReclassifyWorker` resolves credentials ONCE per kick
    # and the router re-decides the PROVIDER per article from a SECOND, independently
    # cached settings read. The two CAN disagree — a mid-batch provider flip, a
    # cluster invalidation, a TTL refresh — and the pre-resolved credential would
    # then be handed to the wrong sibling. The router must forward pre-resolved
    # credentials only when the caller TAGGED them with the provider now dispatching.
    test "ClassifierRouter STRIPS pre-resolved credentials tagged for another provider" do
      tenant = openai_tenant()
      test_pid = self()

      Req.Test.stub(Anthropic, fn conn ->
        send(test_pid, :anthropic_was_called)
        Req.Test.json(conn, %{"content" => [%{"type" => "text", "text" => "{}"}]})
      end)

      Req.Test.stub(Loopctl.Llm.OpenAiChat, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:openai, conn.req_headers, JSON.decode!(raw)})

        Req.Test.json(conn, %{
          "choices" => [
            %{"message" => %{"content" => ~s({"category":"pattern","confidence":0.9})}}
          ],
          "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 1}
        })
      end)

      # The batch resolved against Anthropic; the tenant now resolves openai_compatible.
      assert {:ok, %{category: :pattern}} =
               ClassifierRouter.classify(tenant.id, "T", "B",
                 provider: :anthropic,
                 api_key: "sk-ant-batch-resolved",
                 model: "claude-haiku-4-5-20251001"
               )

      refute_received :anthropic_was_called
      assert_received {:openai, headers, body}

      # The OpenAI sibling re-resolved its OWN credential and model — the Anthropic
      # key never left, and the Anthropic MODEL id was not posted to the local server.
      assert {"authorization", "Bearer local-tenant-b-secret"} in headers
      assert body["model"] == "llama-3.1-8b-instruct"
      refute inspect(headers) =~ "sk-ant-batch-resolved"
    end
  end

  describe "default unchanged (AC-41.3.7)" do
    test "a tenant that configures NOTHING keeps Anthropic and the hardcoded endpoint" do
      tenant = fixture(:tenant)

      assert Llm.chat_provider(tenant.id) == :anthropic
      assert Llm.chat_base_url(tenant.id) == Anthropic.base_url()

      assert ContentExtractorRouter.sibling_for(tenant.id) ==
               Loopctl.Knowledge.ClaudeContentExtractor
    end

    test "a tenant with ONLY an Anthropic key resolves the unchanged Anthropic target" do
      tenant = anthropic_tenant()

      assert {:ok, resolved} = Llm.resolve(tenant.id, :extraction)
      assert resolved.provider == :anthropic
      assert resolved.base_url == Anthropic.base_url()
      assert resolved.api_key == "sk-ant-tenant-a-secret"
    end
  end
end
