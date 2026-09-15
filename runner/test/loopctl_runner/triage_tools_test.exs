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

  test "an argv missing any containment flag is refused at launch" do
    # Before the seam every launch went through claude_args/3, which pins these. A supplied argv
    # that omits one launches an unattended session with the operator's settings, hooks, plugins
    # and MCP servers — and nothing else in Session would notice.
    for {flag, _} <- [
          {"--setting-sources", ""},
          {"--permission-mode", "dontAsk"},
          {"--disallowedTools", "mcp__*"},
          {"--mcp-config", ""},
          # The values of these two are the run type's own, so the guard pins only their
          # presence — and their absence is not cosmetic: without --tools the session's pool
          # goes back to Agent, Workflow, Skill, SendMessage, WebFetch and every plugin tool
          # (--disallowedTools mcp__* covers only the MCP half), and without --max-turns an
          # unattended session has no turn ceiling at all.
          {"--tools", ""},
          {"--max-turns", ""}
        ] do
      argv =
        TriageTools.claude_args("p", "the-id", TriagePrompt.system_prompt(), max_turns: 5)
        |> drop_flag(flag)

      assert {:session_start_failed, {%ArgumentError{message: message}, _}} =
               catch_exit(launch(argv, "the-id"))

      assert message =~ flag, "#{flag} was not required"
    end
  end

  defp drop_flag(argv, flag) do
    index = Enum.find_index(argv, &(&1 == flag))
    List.delete_at(List.delete_at(argv, index), index)
  end

  defp launch(argv, session_id) do
    story = %LoopctlRunner.Story{
      id: "t",
      repo: "r",
      repo_path: "/tmp",
      base: "main",
      branch: "loop/t",
      prompt: "p",
      wall_clock_s: 60,
      max_turns: 5
    }

    root = LoopctlRunner.TestSupport.tmp_dir!("argv")

    LoopctlRunner.Session.run(
      config: LoopctlRunner.TestSupport.config!(root),
      story: story,
      worktree: root,
      run_dir: LoopctlRunner.TestSupport.tmp_dir!("argv-run"),
      trace: self(),
      parent: nil,
      session_id: session_id,
      argv: argv
    )
  end

  test "an argv whose session id is not the session's is refused at launch" do
    # LOOP_SESSION_ID, the process-group marker and the liveness transcript check are keyed to the
    # id the Session tracks; an argv running under a different one makes a healthy session look
    # parked, and the runner then terminates it.
    argv = TriageTools.claude_args("p", "another-id", TriagePrompt.system_prompt(), max_turns: 5)

    # The guard raises inside Session.init, which the GenServer turns into a start failure. The
    # run directory is this test's own: Session writes state and stdout before the guard runs.
    assert {:session_start_failed, {%ArgumentError{message: message}, _}} =
             catch_exit(launch(argv, "the-tracked-id"))

    assert message =~ "--session-id"
    assert message =~ "the-tracked-id"
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
