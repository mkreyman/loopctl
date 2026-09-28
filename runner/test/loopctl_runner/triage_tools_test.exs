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

  defp launch(argv, session_id, opts \\ []) do
    {root, opts} =
      Keyword.pop_lazy(opts, :root, fn -> LoopctlRunner.TestSupport.tmp_dir!("argv") end)

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

    LoopctlRunner.Session.run(
      Keyword.merge(
        [
          config: LoopctlRunner.TestSupport.config!(root),
          story: story,
          worktree: root,
          run_dir: LoopctlRunner.TestSupport.tmp_dir!("argv-run"),
          trace: self(),
          parent: nil,
          session_id: session_id,
          argv: argv
        ],
        opts
      )
    )
  end

  test "a refused argv arms no git grant, so a refusal leaks none" do
    # The argv is checked inside `init/1`, and a raise there never reaches `terminate/2`, which is
    # where a grant is removed. Checked FIRST, a refusal leaves the grant directory as it was.
    root = LoopctlRunner.TestSupport.tmp_dir!("argv-grant")

    argv =
      TriageTools.claude_args("p", "the-id", TriagePrompt.system_prompt(), max_turns: 5)
      |> drop_flag("--permission-prompts")

    assert {:session_start_failed, {%ArgumentError{}, _}} =
             catch_exit(launch(argv, "the-id", own_worktree: true, root: root))

    assert File.ls(LoopctlRunner.TestSupport.config!(root).grant_dir) in [
             {:ok, []},
             {:error, :enoent}
           ]
  end

  test "a launch that fails leaves no grant behind" do
    # terminate/2 never runs for an init that raises, and the grant's owner is the daemon BEAM,
    # which outlives the session — so no sweep would ever remove it. A cwd that does not exist
    # fails the launch past the arming (the child cannot change into it, so the Port has no OS
    # process to report) and launches nothing.
    root = LoopctlRunner.TestSupport.tmp_dir!("launch-grant")
    argv = TriageTools.claude_args("p", "the-id", TriagePrompt.system_prompt(), max_turns: 5)
    gone = Path.join(root, "no-such-worktree")

    assert {:session_start_failed, _} =
             catch_exit(launch(argv, "the-id", own_worktree: true, root: root, worktree: gone))

    # The grant is armed only once the Port is open, so a launch refused there may never have
    # created the directory at all. Either way, no grant is left behind.
    assert File.ls(LoopctlRunner.TestSupport.config!(root).grant_dir) in [
             {:ok, []},
             {:error, :enoent}
           ]
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

      # The gate compares entries WHOLE, so the codes are spelled here exactly or they never fire.
      # A lens reports them and the session carries them into the verdict; that split is this
      # repo's, because a lens here does not state a verdict at all.
      assert prompt =~ "workflow_change_not_defect_fix", "#{name}: the workflow gating code"
      assert prompt =~ "inverts_or_removes_deliberate_behaviour", "#{name}: the inverts code"
      assert prompt =~ "already_implemented_at_head", "#{name}: the already-satisfied code"
      assert prompt =~ "never invent one", "#{name}"
      # BARE: a code in backticks is a different string to a whole-entry match.
      assert prompt =~ "WRITE THE CODE BARE", "#{name}"

      for code <- ~w(workflow_change_not_defect_fix inverts_or_removes_deliberate_behaviour
                     already_implemented_at_head) do
        refute prompt =~ "`" <> code, "#{name}: #{code} shown wrapped"
        refute prompt =~ code <> "`", "#{name}: #{code} shown wrapped"
      end

      # EVERY published code is named, and named from the one vocabulary. The literals above are
      # what catches a rewording; this is what catches the transcription coming back — a lens told
      # the old spelling while the session prompt carries the new one gates nothing, and the split
      # between the two prompts is exactly where that goes unnoticed.
      codes = LoopctlRunner.TriagePrompt.reason_codes()

      for code <- codes.gating ++ codes.soft do
        # As a WHOLE TOKEN, never as a substring. A gate compares entries whole, so a lens told
        # `already_implemented_at_head_OLD` reports a string that matches nothing — and `prompt =~
        # code` passes on it, because the stale spelling contains the live one. Mutation-checked:
        # the substring form stayed green under exactly that edit.
        assert prompt =~ ~r/(?<![\w-])#{Regex.escape(code)}(?![\w-])/,
               "#{name}: #{code} is published and no lens is told to report it, bare"
      end

      assert codes.gating ==
               LoopctlRunner.Contract.connection() |> Map.fetch!("triage_gating_reasons")

      # And a lens still states no verdict, in any wording: "the verdict should escalate" is
      # stating one, and it would make the lenses disagreeing unrepresentable.
      refute prompt =~ "verdict should", "#{name}"
      # Nor by deciding what the outcome is NOT: that rule is whole in the session's prompt, and
      # half of it here is a lens judging an outcome in the one place it must not.
      refute prompt =~ "It is not a reject", "#{name}"

      # The operational test is carried in ITS OWN WORDS: the measurement that justifies it is a
      # measurement of these words, so a paraphrase is a different rule with borrowed evidence.
      assert prompt =~ "Does the CURRENT behaviour match what the system was built to do?",
             "#{name}"

      assert prompt =~
               "A request for something the system never attempted at all is a workflow change.",
             "#{name}"

      refute prompt =~ ~r/\S  +\S/, "#{name}: the quote carries line-join padding"

      # And the four outcomes of reading the code, which is what stops every ordinary defect
      # being filed as already-implemented.
      assert prompt =~ "The read has exactly four outcomes", "#{name}"
      assert prompt =~ "SETTLES the claim", "#{name}"

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
