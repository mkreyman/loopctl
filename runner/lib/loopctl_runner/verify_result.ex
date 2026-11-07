defmodule LoopctlRunner.VerifyResult do
  @moduledoc """
  What a `verify@1` session's final block becomes before it is judged and sent (US-48.18): the
  verdict and findings the SESSION stated, and the head the RUNNER checked out.

  The session ends its final message with one fenced ```` ```json ```` block,
  `{"verdict": "pass" | "reject", "findings": [...]}`, read by `LoopctlRunner.AgentResult` exactly
  as a draft's is. `complete/2` then makes it a result for verify@1's schema (contract 1.28.0,
  `{verdict, head_sha, findings}`), and everything it refuses sends NOTHING — which is how a
  malformed verdict is never a pass: the dispatch's verifier lapses and loopctl places the story
  again (`rerun: :next_pass`).

  ## Whose head

  `head_sha` is what loopctl matches the verdict to the story's current head by, so it is the
  commit the tree the session judged was at (`TriageRun` reads it off the tree after the cut and
  refuses a tree that is not at the dispatch's head). The session is not asked for it. One that
  states a head anyway must state THAT one: a session that names another commit was looking at
  something other than what the runner gave it, and its verdict is about that, not about this.

  ## What is refused beyond the schema

  - a `pass` that carries findings: a session that names what fails has not passed it, and
    sending `pass` would verify the story with those findings unread;
  - any key but `verdict`, `findings` and `head_sha`, as the schema refuses it — said here so
    the reason names the session's block rather than the runner's result.

  `findings` absent is `[]`. A `reject` with none is admitted: loopctl sends the story back
  saying no finding was named, which is still the truth of what the session said.
  """

  @keys ~w(verdict findings head_sha)

  @doc """
  The verify@1 result for `stated` (the session's decoded block) judged at `head`, the commit the
  runner checked out: `{:ok, result}`, or `{:error, reason}` in the runner's words.
  """
  @spec complete(map(), String.t()) :: {:ok, map()} | {:error, String.t()}
  def complete(stated, head) when is_map(stated) and is_binary(head) do
    findings = Map.get(stated, "findings", [])

    cond do
      (extra = Map.keys(stated) -- @keys) != [] ->
        {:error,
         "the session's verdict block carries #{length(extra)} key(s) besides verdict and findings"}

      Map.has_key?(stated, "head_sha") and stated["head_sha"] != head ->
        {:error, "the session's verdict names a head other than the one the runner checked out"}

      stated["verdict"] == "pass" and findings != [] ->
        {:error, "the session's verdict is pass but it names findings"}

      true ->
        {:ok, %{"verdict" => stated["verdict"], "findings" => findings, "head_sha" => head}}
    end
  end
end
