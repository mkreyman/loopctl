defmodule LoopctlRunner.ReplyDraftPromptTest do
  use ExUnit.Case, async: true

  alias LoopctlRunner.{AgentResult, ReplyDraftPrompt}

  @triage %{
    "record_id" => "7d0c1f6e-3b1a-4f7e-9c2d-5a6b7c8d9e0f",
    "issue_number" => 846,
    "truncated" => false,
    "untrusted" => "<<<UNTRUSTED reported_issue n0nce>>>\n| it crashes\n<<<END n0nce>>>"
  }

  test "AC-48.9.4: the argv carries no tool list, the same posture as every unattended session" do
    argv = ReplyDraftPrompt.claude_args("PROMPT", "sid", max_turns: 7, model: nil)

    for flag <- ~w(--tools --allowedTools --allowed-tools --disallowedTools --disallowed-tools
                   --strict-mcp-config --setting-sources),
        do: refute(flag in argv, "#{flag} restricts what the operator's setup grants")

    assert ["--permission-mode", "bypassPermissions"] ==
             Enum.drop_while(argv, &(&1 != "--permission-mode")) |> Enum.take(2)

    assert ["--max-turns", "7"] == Enum.drop_while(argv, &(&1 != "--max-turns")) |> Enum.take(2)
    # No lenses to dispatch: a draft is one session.
    refute "--agents" in argv
    assert Enum.take(argv, -2) == ["--", "PROMPT"]

    assert ["--model", "opus"] ==
             ReplyDraftPrompt.claude_args("P", "sid", max_turns: 1, model: "opus")
             |> Enum.drop_while(&(&1 != "--model"))
             |> Enum.take(2)
  end

  test "the system prompt says a person reviews the draft and nothing is sent by the session" do
    system = ReplyDraftPrompt.system_prompt()
    assert system =~ "a person reviews it before anything is sent"
    assert system =~ "You write nothing"
    refute system =~ "loop-escalate"
  end

  test "the prompt forbids promises, says a human sends it, and ends in one json block" do
    prompt = ReplyDraftPrompt.build(@triage, "mkreyman/fixture")

    assert prompt =~ "A person reads it"
    assert prompt =~ "NEVER promise a date, a release, a fix"
    assert prompt =~ "exactly ONE fenced json"
    assert prompt =~ "at most #{AgentResult.reply_draft_max_body()} characters"
    assert String.contains?(prompt, @triage["untrusted"])
  end

  test "an empty report is not pasted as a fence, and a truncated one is said" do
    empty = ReplyDraftPrompt.build(%{@triage | "untrusted" => "  "}, "r")
    assert empty =~ "carries no text at all"
    refute empty =~ "The report follows"

    cut = ReplyDraftPrompt.build(%{@triage | "truncated" => true}, "r")
    assert cut =~ "wrote MORE than you can see"
  end
end
