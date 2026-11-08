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

  ## A reject's findings are clipped, never the reason to lose it

  A `reject` whose findings overrun verify@1's bounds is still a reject. Each finding longer than
  the schema's `maxLength` (counted in code points, as loopctl counts) is cut to fit and ends in
  `…`, and findings past `maxItems` are dropped, the last kept one saying how many were. Refusing
  it instead sent nothing, so the verifier lapsed, loopctl placed the story again, and the next
  session wrote the same long finding: on 2026-11-08 HCB story 900.224's reject was lost this way
  on one finding over the 300-character cap. Clipping changes only the wording a rework session reads, never the
  verdict, and a `pass` is untouched because it carries no findings to clip.
  """

  alias LoopctlRunner.{AgentResult, Contract}

  @keys ~w(verdict findings head_sha)
  @ellipsis "…"

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
        {:ok,
         %{
           "verdict" => stated["verdict"],
           "findings" => fit(stated, findings),
           "head_sha" => head
         }}
    end
  end

  # Only a reject's findings are fitted, and only when EVERY one is a finding the schema admits
  # apart from its length: judged against verify@1's own items schema with `maxLength` removed,
  # before anything is cut or dropped. Otherwise the list reaches the schema as stated and is
  # refused there, so a blank finding is never dressed in an ellipsis nor dropped unseen past
  # maxItems, and a malformed block is still never sent.
  defp fit(%{"verdict" => "reject"}, findings) when is_list(findings) do
    if Enum.all?(findings, &admitted_but_for_length?/1),
      do: findings |> cap_count() |> Enum.map(&clip/1),
      else: findings
  end

  defp fit(_stated, findings), do: findings

  defp admitted_but_for_length?(finding) do
    {:ok, schema} = AgentResult.schema({"verify", 1})
    item = schema |> get_in(["properties", "findings", "items"]) |> Map.delete("maxLength")
    Contract.validate_against(item, finding, "finding") == :ok
  end

  defp cap_count(findings) do
    max = AgentResult.verify_max_findings()

    case Enum.split(findings, max) do
      {kept, []} ->
        kept

      {kept, dropped} ->
        {head, [last]} = Enum.split(kept, max - 1)
        head ++ [clip_to(last, " (#{length(dropped)} more finding(s) cut)")]
    end
  end

  defp clip(finding), do: clip_to(finding, "")

  # `finding` with `suffix` appended, cut so the whole fits the schema's maxLength in code points.
  # The cut is `Contract.fit/3`'s, so it never splits a character.
  defp clip_to(finding, suffix) do
    room = AgentResult.verify_max_finding_length() - Contract.codepoints(suffix)
    Contract.fit(finding, room, @ellipsis) <> suffix
  end
end
