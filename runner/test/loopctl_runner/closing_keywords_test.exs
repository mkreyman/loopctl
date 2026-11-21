defmodule LoopctlRunner.ClosingKeywordsTest do
  use ExUnit.Case, async: true

  alias LoopctlRunner.ClosingKeywords

  test "every GitHub closing keyword before an issue reference becomes Refs" do
    for word <- ~w(close closes closed fix fixes fixed resolve resolves resolved Closes FIXES) do
      assert ClosingKeywords.neutralize("#{word} #15") == "Refs #15"
      assert ClosingKeywords.neutralize("#{word}: #15") == "Refs #15"
    end
  end

  test "a cross-repository reference and an issue URL are rewritten too" do
    assert ClosingKeywords.neutralize("Fixes mkreyman/loopctl-e2e-sandbox#15.") ==
             "Refs mkreyman/loopctl-e2e-sandbox#15."

    assert ClosingKeywords.neutralize("Resolves https://github.com/a/b/issues/7") ==
             "Refs https://github.com/a/b/issues/7"
  end

  test "each keyword of several is rewritten, and the rest of the text is kept" do
    assert ClosingKeywords.neutralize("Closes #1, closes #2.\nSee also #3.") ==
             "Refs #1, Refs #2.\nSee also #3."
  end

  test "a keyword not followed by an issue, or inside a word, is prose and is left alone" do
    for text <- ["Fix the run id.", "the fixes land in #15's sibling", "prefixed #15", "Refs #15"] do
      assert ClosingKeywords.neutralize(text) == text
    end
  end
end
