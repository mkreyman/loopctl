defmodule Loopctl.Knowledge.ClaudeCategoryClassifierTest do
  use Loopctl.DataCase, async: true

  alias Loopctl.Knowledge.ClaudeCategoryClassifier
  alias Loopctl.Llm

  describe "classify/3 graceful degradation" do
    test "returns {:error, :no_api_key} when the tenant has no Anthropic key (mandatory BYO)" do
      # The tenant has no configured key, so the real classifier must degrade
      # rather than attempt a live HTTP call. This is what keeps the
      # reclassification backfill from mutating data with a placeholder verdict.
      tenant = fixture(:tenant)

      assert {:error, :no_api_key} =
               ClaudeCategoryClassifier.classify(tenant.id, "Some title", "Some body")
    end
  end

  describe "classify/4 end-to-end (Req.Test seam, review #11)" do
    test "uses the tenant's key + classification model and records usage" do
      tenant = fixture(:tenant)

      {:ok, _} =
        Llm.upsert_settings(tenant.id, %{
          "api_key" => "sk-ant-classify-777",
          "classification_model" => "claude-sonnet-4-5"
        })

      Req.Test.stub(Loopctl.Llm.Anthropic, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(self(), {:req, conn.req_headers, JSON.decode!(body)})

        Req.Test.json(conn, %{
          "content" => [
            %{"type" => "text", "text" => ~s({"category":"playbook","confidence":0.9})}
          ],
          "usage" => %{"input_tokens" => 12, "output_tokens" => 4}
        })
      end)

      assert {:ok, %{category: :playbook, confidence: 0.9}} =
               ClaudeCategoryClassifier.classify(tenant.id, "Title", "Body")

      assert_received {:req, headers, req_body}
      assert {"x-api-key", "sk-ant-classify-777"} in headers
      assert req_body["model"] == "claude-sonnet-4-5"

      %{data: [row]} = Llm.usage_summary(tenant.id, [])
      assert row.operation == :classification
      assert row.model == "claude-sonnet-4-5"
      assert row.input_tokens == 12
      assert row.output_tokens == 4
    end

    test "accepts pre-resolved credentials (review #19 batch path) without re-resolving" do
      tenant = fixture(:tenant)
      # NO settings row — proves classify uses the passed creds, not resolve/2.
      Req.Test.stub(Loopctl.Llm.Anthropic, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(self(), {:req, conn.req_headers, JSON.decode!(body)})

        Req.Test.json(conn, %{
          "content" => [
            %{"type" => "text", "text" => ~s({"category":"pattern","confidence":0.8})}
          ],
          "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
        })
      end)

      assert {:ok, %{category: :pattern}} =
               ClaudeCategoryClassifier.classify(tenant.id, "T", "B",
                 api_key: "sk-ant-preresolved",
                 model: "claude-haiku-4-5-20251001"
               )

      assert_received {:req, headers, req_body}
      assert {"x-api-key", "sk-ant-preresolved"} in headers
      assert req_body["model"] == "claude-haiku-4-5-20251001"
    end
  end

  describe "parse_text/1" do
    test "parses a clean compact JSON object" do
      assert {:ok, %{category: :playbook, confidence: 0.9}} =
               ClaudeCategoryClassifier.parse_text(~s({"category":"playbook","confidence":0.9}))
    end

    test "tolerates a markdown ```json fence" do
      text = "```json\n{\"category\": \"insight\", \"confidence\": 0.8}\n```"

      assert {:ok, %{category: :insight, confidence: 0.8}} =
               ClaudeCategoryClassifier.parse_text(text)
    end

    test "tolerates a prose preamble and trailing text around the object" do
      text = ~s(Here is the classification: {"category":"entity","confidence":0.7}. Done.)

      assert {:ok, %{category: :entity, confidence: 0.7}} =
               ClaudeCategoryClassifier.parse_text(text)
    end

    test "coerces an integer confidence to a float" do
      assert {:ok, %{category: :pattern, confidence: 1.0}} =
               ClaudeCategoryClassifier.parse_text(~s({"category":"pattern","confidence":1}))
    end

    test "rejects an echoed prompt template (the original prod failure mode)" do
      # The model echoing the literal format example -- '<one of: ...>' is not
      # valid JSON and must be rejected, not crash.
      text =
        ~s({"category": "<one of: pattern, decision>", "confidence": <number between 0 and 1>})

      assert {:error, :unparseable_classification} = ClaudeCategoryClassifier.parse_text(text)
    end

    test "rejects a category that is not active (e.g. the retired convention)" do
      assert {:error, :unparseable_classification} =
               ClaudeCategoryClassifier.parse_text(~s({"category":"convention","confidence":0.9}))

      assert {:error, :unparseable_classification} =
               ClaudeCategoryClassifier.parse_text(~s({"category":"banana","confidence":0.9}))
    end

    test "rejects a non-numeric confidence and non-JSON / nil input" do
      assert {:error, :unparseable_classification} =
               ClaudeCategoryClassifier.parse_text(~s({"category":"pattern","confidence":"high"}))

      assert {:error, :unparseable_classification} =
               ClaudeCategoryClassifier.parse_text("I think this is a pattern.")

      assert {:error, :unparseable_classification} = ClaudeCategoryClassifier.parse_text(nil)
    end
  end
end
