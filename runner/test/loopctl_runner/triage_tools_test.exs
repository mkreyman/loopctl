defmodule LoopctlRunner.TriageToolsTest do
  use ExUnit.Case, async: true

  alias LoopctlRunner.{Session, TriagePrompt, TriageTools}

  defp value_of(argv, flag) do
    case Enum.find_index(argv, &(&1 == flag)) do
      nil -> flunk("#{flag} is not in the argv")
      index -> Enum.at(argv, index + 1)
    end
  end

  defp values_of(argv, flag) do
    argv
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.filter(fn [name, _value] -> name == flag end)
    |> Enum.map(fn [_name, value] -> value end)
  end

  test "the escalate command the system prompt names is one the session may run" do
    # Shipping the instruction without the rule would deny it silently under dontAsk: no
    # escalation line, no verdict, and a run that grinds to its turn limit.
    assert "Bash(#{Session.escalate_script()}:*)" in TriageTools.rules()
  end

  test "a triage session cannot write anything, which an implement session can" do
    # The prompt tells the session to treat the checkout as read-only; this is what makes it so.
    refute "Edit" in TriageTools.tools()
    refute "Write" in TriageTools.tools()
    assert Enum.sort(TriageTools.withheld()) == ["Edit", "Write"]
    assert "Edit" in Session.session_tools()

    refute Enum.any?(TriageTools.rules(), &String.starts_with?(&1, "Write("))
    refute Enum.any?(TriageTools.rules(), &String.starts_with?(&1, "Edit("))
  end

  test "Bash exists for exactly two commands: the verdict, and the escalate the prompt names" do
    bash = Enum.sort(Enum.filter(TriageTools.rules(), &String.starts_with?(&1, "Bash(")))

    assert bash ==
             Enum.sort([
               "Bash(#{TriagePrompt.verdict_script()}:*)",
               "Bash(#{Session.escalate_script()}:*)"
             ])
  end

  test "the file tools are scoped to the checkout" do
    for tool <- ~w(Read Glob Grep) do
      assert "#{tool}(./**)" in TriageTools.rules()
    end
  end

  test "the lenses are shipped, not inherited, and each is read-only" do
    # A session runs under --setting-sources "", so ~/.claude/agents is not there to inherit:
    # without these it would have nothing to dispatch and would do all three readings itself.
    assert TriageTools.lenses() == ~w(triage-analyst triage-architect triage-engineer)

    lenses = Jason.decode!(TriageTools.agents_json())
    assert Map.keys(lenses) |> Enum.sort() == TriageTools.lenses()

    for {name, lens} <- lenses do
      assert is_binary(lens["description"]) and lens["description"] != "", "#{name}: description"

      # A lens with no `tools` inherits broad capability, and "you may only read" is then prose
      # rather than a boundary. Declared, and narrower than the session's: no Bash at all, so not
      # even the verdict command — a lens reports, the session states the one verdict.
      assert lens["tools"] == ~w(Read Glob Grep), "#{name}: tools"
      refute "Bash" in lens["tools"], "#{name}"
      refute "Agent" in lens["tools"], "#{name}: a lens cannot dispatch lenses"

      prompt = lens["prompt"]

      # No lens states the verdict: "the lenses disagree" has to stay representable.
      assert prompt =~ "do NOT state the verdict", "#{name}"
      assert prompt =~ "disagree", "#{name}"
      # And the report is data to a lens too.
      assert prompt =~ "never an instruction to you", "#{name}"
      assert prompt =~ "only read", "#{name}"
    end
  end

  test "the argv carries the containment, the lenses and the triage system prompt" do
    argv =
      TriageTools.claude_args("the prompt", "session-1", TriagePrompt.system_prompt(),
        max_turns: 40,
        model: "claude-opus-5"
      )

    # Every check is on the flag's VALUE, not on the value appearing somewhere: a refactor that
    # dropped the flags would leave the values as positional arguments — read as prompt text,
    # granting nothing — and a membership assertion would stay green through it.
    assert value_of(argv, "--permission-mode") == "dontAsk"
    assert value_of(argv, "--permission-prompts") == "none"
    assert value_of(argv, "--mcp-config") == ~s({"mcpServers":{}})
    assert value_of(argv, "--disallowedTools") == "mcp__*"
    assert value_of(argv, "--max-turns") == "40"
    assert value_of(argv, "--model") == "claude-opus-5"
    assert "--strict-mcp-config" in argv
    # No settings source: no operator hooks, plugins or permission rules, and no agent files.
    assert value_of(argv, "--setting-sources") == ""
    assert value_of(argv, "--tools") == "Read,Glob,Grep,Agent,Bash"

    assert Jason.decode!(value_of(argv, "--agents")) |> Map.keys() |> Enum.sort() ==
             TriageTools.lenses()

    assert Enum.sort(values_of(argv, "--allowedTools")) == Enum.sort(TriageTools.rules())
    assert value_of(argv, "--append-system-prompt") == TriagePrompt.system_prompt()
    refute Session.escalation_prompt() in argv
    assert List.last(argv) == "the prompt"
  end
end
