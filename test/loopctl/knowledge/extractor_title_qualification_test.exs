defmodule Loopctl.Knowledge.ExtractorTitleQualificationTest do
  @moduledoc """
  The ingestion ROOT CAUSE behind the duplicate-capture class (#617).

  The extractor mints every article title. It was shown only a coarse `source_type`
  ("web_article"), never WHICH document it was reading — so a CHANGELOG file could
  only be titled "Changelog", and on the hosted corpus three unrelated documents (a
  WordPress SEO plugin, the Elixir oauth2 library, a WordPress theme) each produced
  exactly that. Those three then collided on the normalized title and were proposed
  for auto-unpublish as "the same capture", which is the false grouping 23 articles
  were retitled by hand on 2026-08-06 to clear.

  An extractor cannot qualify a title with a source it was never shown. These tests
  pin that it IS shown one, and that the prompt asks for the qualification.
  """

  use ExUnit.Case, async: true

  alias Loopctl.Knowledge.ClaudeContentExtractor

  describe "user_content/3 carries the SPECIFIC source" do
    test "names the source when one is known" do
      message =
        ClaudeContentExtractor.user_content(
          "# Changelog\n\n## 1.2.0",
          "web_article",
          "https://github.com/scrogson/oauth2/blob/master/CHANGELOG.md"
        )

      assert message =~ "Source: https://github.com/scrogson/oauth2"
      assert message =~ "Source type: web_article"
      assert message =~ "# Changelog"
    end

    test "omits the source line entirely when there is none" do
      # Deliberately NOT a placeholder. A model handed `Source: unknown` will dutifully
      # qualify a title with it — "Changelog -- unknown" is worse than "Changelog",
      # because it looks specific while distinguishing nothing.
      for missing <- [nil, ""] do
        message = ClaudeContentExtractor.user_content("body", "inline", missing)

        refute message =~ "Source:"
        refute message =~ "unknown"
      end
    end

    test "the two-arity form still works for callers that have no source" do
      # `OpenAiContentExtractor` shares this function; the default keeps the behaviour
      # of every caller that has not been taught about `:source_ref`.
      assert ClaudeContentExtractor.user_content("body", "newsletter") =~
               "Source type: newsletter"
    end
  end

  describe "the system prompt asks for a title that stands alone" do
    test "names the generic-title trap and the qualification it wants instead" do
      prompt = ClaudeContentExtractor.system_prompt()

      # The instruction has to be concrete about WHICH titles are the problem — a vague
      # "write good titles" changes nothing, and this exact class is what the corpus
      # actually produced.
      assert prompt =~ "Changelog"
      assert prompt =~ "Configuration"

      # ...and it must ask for the SOURCE as the qualifier, which is only actionable
      # because `user_content/3` now supplies one.
      assert prompt =~ "Source line"
    end

    test "tells the model NOT to pad an already-specific title" do
      # Without this the rule over-fires and every title grows a source suffix, which
      # makes the corpus noisier rather than more distinguishable.
      assert ClaudeContentExtractor.system_prompt() =~ "do not pad it"
    end

    test "both providers share ONE prompt, so the rule cannot drift" do
      # `OpenAiContentExtractor` calls `system_prompt/0` and `user_content/3` rather
      # than carrying copies; a copy would let one provider keep minting bare
      # "Changelog" titles into the same corpus.
      source = File.read!("lib/loopctl/knowledge/openai_content_extractor.ex")

      assert source =~ "ClaudeContentExtractor.system_prompt()"
      assert source =~ "ClaudeContentExtractor.user_content(content, source_type, source_ref)"
    end
  end
end
