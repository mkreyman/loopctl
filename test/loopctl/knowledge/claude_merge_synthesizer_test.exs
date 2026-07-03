defmodule Loopctl.Knowledge.ClaudeMergeSynthesizerTest do
  use Loopctl.DataCase, async: true

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

  describe "synthesize/3 without a configured backend" do
    test "returns :no_api_key rather than a placeholder (mandatory BYO)" do
      # The tenant has no configured key → graceful degrade, no live HTTP call.
      tenant = fixture(:tenant)

      assert {:error, :no_api_key} =
               Synth.synthesize(tenant.id, %{title: "A", body: "a"}, %{title: "B", body: "b"})
    end
  end
end
