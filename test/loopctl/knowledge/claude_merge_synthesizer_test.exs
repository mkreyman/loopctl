defmodule Loopctl.Knowledge.ClaudeMergeSynthesizerTest do
  use ExUnit.Case, async: true

  alias Loopctl.Knowledge.ClaudeMergeSynthesizer, as: Synth

  describe "parse_text/1" do
    test "parses a clean JSON object" do
      assert {:ok, %{title: "T", body: "B"}} =
               Synth.parse_text(~s({"title": "T", "body": "B"}))
    end

    test "tolerates markdown fences and surrounding prose" do
      text = "Here you go:\n```json\n{\"title\": \"Merged\", \"body\": \"Body text\"}\n```\n"
      assert {:ok, %{title: "Merged", body: "Body text"}} = Synth.parse_text(text)
    end

    test "rejects empty title or body" do
      assert {:error, :unparseable_merge} = Synth.parse_text(~s({"title": "", "body": "B"}))
      assert {:error, :unparseable_merge} = Synth.parse_text(~s({"title": "T", "body": "   "}))
    end

    test "rejects non-JSON / missing keys / nil" do
      assert {:error, :unparseable_merge} = Synth.parse_text("not json")
      assert {:error, :unparseable_merge} = Synth.parse_text(~s({"title": "T"}))
      assert {:error, :unparseable_merge} = Synth.parse_text(nil)
    end
  end

  describe "synthesize/2 without a configured backend" do
    test "returns :not_configured rather than a placeholder" do
      # No :anthropic_provider api_key in :test → graceful degrade.
      assert {:error, :not_configured} =
               Synth.synthesize(%{title: "A", body: "a"}, %{title: "B", body: "b"})
    end
  end
end
