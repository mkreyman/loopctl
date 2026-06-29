defmodule Loopctl.Knowledge.ClaudeCategoryClassifierTest do
  use ExUnit.Case, async: true

  alias Loopctl.Knowledge.ClaudeCategoryClassifier

  describe "classify/2 graceful degradation" do
    test "returns {:error, :not_configured} when no Anthropic API key is set" do
      # No :anthropic_provider key is configured in the test env, so the real
      # classifier must degrade rather than attempt a live HTTP call. This is
      # what keeps the reclassification backfill from mutating data with a
      # placeholder verdict in environments without Anthropic access.
      assert {:error, :not_configured} =
               ClaudeCategoryClassifier.classify("Some title", "Some body")
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
