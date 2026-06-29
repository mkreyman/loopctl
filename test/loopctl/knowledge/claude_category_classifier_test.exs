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
end
