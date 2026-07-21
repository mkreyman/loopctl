defmodule Loopctl.Llm.OpenAiShapeValidationTest do
  @moduledoc """
  TC-41.3.2 — malformed local-model output fails LEGIBLY (US-41.3, AC-41.3.4).

  Local models are weaker at structured output than Claude. Every OpenAI-compatible
  sibling validates the response shape and fails the item with a reason NAMING the
  endpoint and the model; nothing malformed is written, and the failure is
  PERMANENT so it is not retried blindly.
  """
  use Loopctl.DataCase, async: true

  alias Loopctl.Knowledge
  alias Loopctl.Knowledge.OpenAiCategoryClassifier
  alias Loopctl.Knowledge.OpenAiContentExtractor
  alias Loopctl.Knowledge.OpenAiExtractor
  alias Loopctl.Knowledge.OpenAiMergeSynthesizer
  alias Loopctl.Llm
  alias Loopctl.Llm.ShapeError

  @base_url "https://local.example.com/v1"
  @model "llama-3.1-8b-instruct"
  @endpoint "https://local.example.com/v1/chat/completions"

  setup do
    tenant = fixture(:tenant)

    {:ok, _} =
      Llm.upsert_settings(tenant.id, %{
        "chat_provider" => "openai_compatible",
        "chat_base_url" => @base_url,
        "chat_api_key" => "local-key",
        "extraction_model" => @model,
        "classification_model" => @model,
        "merge_model" => @model
      })

    %{tenant: tenant}
  end

  defp stub_content(text) do
    Req.Test.stub(Loopctl.Llm.OpenAiChat, fn conn ->
      Req.Test.json(conn, %{
        "choices" => [%{"message" => %{"content" => text}}],
        "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 1}
      })
    end)
  end

  defp assert_named(details) do
    assert details.endpoint == @endpoint
    assert details.model == @model
    message = ShapeError.message({:invalid_response_shape, details})
    assert message =~ @endpoint
    assert message =~ @model
    assert message =~ "CONFIGURATION problem"
  end

  describe "content extractor" do
    test "prose instead of the required JSON array fails with a named shape error", %{
      tenant: tenant
    } do
      stub_content("Sure! Here are some interesting takeaways from the document...")

      before = Knowledge.count_articles(tenant.id, [])

      assert {:error, {:invalid_response_shape, details}} =
               OpenAiContentExtractor.extract_from_content(tenant.id, "raw",
                 source_type: "newsletter"
               )

      assert details.reason == :not_json
      assert_named(details)

      # AC-41.3.4: no malformed article was written.
      assert Knowledge.count_articles(tenant.id, []) == before
    end

    test "a JSON object that is not an article array fails with :not_a_list", %{tenant: tenant} do
      stub_content(JSON.encode!(%{"summary" => "nope"}))

      assert {:error, {:invalid_response_shape, %{reason: :not_a_list} = details}} =
               OpenAiContentExtractor.extract_from_content(tenant.id, "raw")

      assert_named(details)
    end

    test "a PARTIALLY valid array is refused rather than half-written", %{tenant: tenant} do
      stub_content(
        JSON.encode!([
          %{title: "Good", body: "B", category: "pattern", tags: []},
          %{title: "", body: nil, category: "not-a-category"}
        ])
      )

      assert {:error, {:invalid_response_shape, %{reason: :missing_required_fields} = details}} =
               OpenAiContentExtractor.extract_from_content(tenant.id, "raw")

      assert_named(details)
      assert details.detail =~ "PARTIAL write"
    end

    test "an EXPLICIT empty array is honoured — the model produced the structure", %{
      tenant: tenant
    } do
      stub_content(JSON.encode!([]))
      assert {:ok, []} = OpenAiContentExtractor.extract_from_content(tenant.id, "raw")
    end

    test "a well-formed array still parses (the strict parser is not a blanket refusal)", %{
      tenant: tenant
    } do
      stub_content(JSON.encode!([%{title: "T", body: "B", category: "pattern", tags: ["a"]}]))

      assert {:ok, [%{title: "T", category: :pattern, metadata: metadata}]} =
               OpenAiContentExtractor.extract_from_content(tenant.id, "raw")

      assert metadata["extraction_source"] == "openai_content_extractor"
    end
  end

  describe "review extractor" do
    test "prose fails with a named shape error", %{tenant: tenant} do
      stub_content("I couldn't find anything reusable, sorry!")

      assert {:error, {:invalid_response_shape, %{reason: :not_json} = details}} =
               OpenAiExtractor.extract_articles(tenant.id, %{review_type: "code", summary: "s"})

      assert_named(details)
    end
  end

  describe "classifier" do
    test "prose fails with a named shape error instead of :unparseable_classification", %{
      tenant: tenant
    } do
      stub_content("I think this is probably a pattern article.")

      assert {:error, {:invalid_response_shape, details}} =
               OpenAiCategoryClassifier.classify(tenant.id, "Title", "Body")

      assert details.reason == :missing_required_fields
      assert_named(details)
    end

    test "pre-resolved opts credentials are IGNORED (no cross-provider key reuse)", %{
      tenant: tenant
    } do
      test_pid = self()

      Req.Test.stub(Loopctl.Llm.OpenAiChat, fn conn ->
        send(test_pid, {:headers, conn.req_headers})

        Req.Test.json(conn, %{
          "choices" => [
            %{"message" => %{"content" => ~s|{"category": "pattern", "confidence": 0.9}|}}
          ]
        })
      end)

      assert {:ok, %{category: :pattern}} =
               OpenAiCategoryClassifier.classify(tenant.id, "T", "B",
                 api_key: "sk-ant-from-a-batch-that-resolved-anthropic",
                 model: "claude-haiku-4-5-20251001"
               )

      assert_received {:headers, headers}
      assert {"authorization", "Bearer local-key"} in headers
      refute Enum.any?(headers, fn {_k, v} -> v =~ "sk-ant-" end)
    end
  end

  describe "merge synthesizer" do
    test "prose fails with a named shape error and drafts nothing", %{tenant: tenant} do
      stub_content("Here is a merged version of both articles: ...")

      assert {:error, {:invalid_response_shape, details}} =
               OpenAiMergeSynthesizer.synthesize(
                 tenant.id,
                 %{title: "A", body: "a"},
                 %{title: "B", body: "b"}
               )

      assert details.reason == :missing_required_fields
      assert_named(details)
    end
  end

  describe "the shape failure is PERMANENT, never a blind retry" do
    test "oban_result/1 cancels" do
      shape = ShapeError.new(@endpoint, @model, :not_json, nil)
      assert {:cancel, message} = ShapeError.oban_result(shape)
      assert message =~ @endpoint
      assert message =~ @model
    end
  end
end
