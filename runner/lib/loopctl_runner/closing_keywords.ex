defmodule LoopctlRunner.ClosingKeywords do
  @moduledoc """
  Rewrites GitHub's issue-closing keywords to a plain reference, so a merge the runner makes never
  closes an issue (`LoopctlRunner.MergeRun`).

  loopctl closes the issue a story came from itself (`Loopctl.Delivery.IssueCloser`), and it puts
  its resolution label on BEFORE the close, because the reporting system's webhook fires on the
  close and picks its text by the label it finds. A pull request whose body says `Closes #15`, or
  a squash commit whose message does, closes the issue at the merge with no label on it, and
  loopctl then finds an issue somebody else closed and abandons its closure (2026-11-21, the e2e
  sandbox's issue #15: merged 11:21:04, closed 11:21:05, no resolution label).

  GitHub's keywords are close, closes, closed, fix, fixes, fixed, resolve, resolves and resolved,
  in any case, optionally followed by a colon, then an issue: `#N`, `owner/repo#N`, or the
  issue's URL. Each becomes `Refs <issue>`, which links the issue and closes nothing. A keyword
  not followed by an issue reference is prose and is left alone.
  """

  @keyword ~r/\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)\b[ \t]*:?[ \t]+((?:[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+)?#\d+|https?:\/\/github\.com\/[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\/issues\/\d+)\b/i

  @doc "`text` with every closing keyword before an issue reference rewritten to `Refs`."
  @spec neutralize(String.t()) :: String.t()
  def neutralize(text) when is_binary(text), do: Regex.replace(@keyword, text, "Refs \\1")
end
