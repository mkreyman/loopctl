defmodule LoopctlRunner.HeadlessLauncherCanaryTest do
  @moduledoc """
  This repo's own copy of claude-config's headless-launcher canary (design §8).

  `ANTHROPIC_API_KEY` in the environment silently outranks the claude.ai login; the
  incident cost about USD 300 and reported a usage limit rather than an auth error.
  claude-config's canary only scans claude-config's own files, so nothing there would
  notice this runner spawning `claude` directly. This test does.

  The runtime half — that the key really is absent in the CLI's environment — is
  asserted end to end in `LoopctlRunner.RunTest`.
  """

  use ExUnit.Case, async: true

  @root Path.expand("..", __DIR__)

  # Any way Elixir or a shell script could start the bare CLI.
  @direct [
    ~r/System\.cmd\(\s*"claude"/,
    ~r/spawn_executable,\s*"[^"]*\/claude"/,
    ~r/Port\.open\(\s*\{:spawn,\s*"claude[\s"]/,
    ~r/:os\.cmd\(\s*~c?'?"?claude[\s'"]/,
    ~r/System\.find_executable\(\s*"claude"\s*\)/,
    ~r/^\s*(exec\s+)?claude\s+-/m,
    ~r/\$\(\s*command -v claude\s*\)/
  ]

  test "no shipped source starts the claude CLI except through claude-headless.sh" do
    {files, 0} =
      System.cmd("git", [
        "-C",
        @root,
        "ls-files",
        "--cached",
        "--others",
        "--exclude-standard",
        "lib",
        "priv",
        "config",
        "rel"
      ])

    # `--others` lists untracked files, and one another process writes and removes meanwhile (seen
    # 2026-11-21: a `config/dev.exs` gone by the time it was read) can no longer start anything.
    offenders =
      for rel <- String.split(files, "\n", trim: true),
          {:ok, content} <- [File.read(Path.join(@root, rel))],
          pattern <- @direct,
          content =~ pattern,
          do: {rel, Regex.source(pattern)}

    assert offenders == []
  end

  test "the canary's patterns catch the shapes they claim to" do
    for bad <- [
          ~s|System.cmd("claude", ["-p", "x"])|,
          ~s|Port.open({:spawn_executable, "/home/u/.local/bin/claude"}, [])|,
          ~s|Port.open({:spawn, "claude -p x"}, [])|,
          "exec claude -p \"$PROMPT\"",
          "  claude -p hi"
        ] do
      assert Enum.any?(@direct, &(bad =~ &1)), "not caught: #{bad}"
    end
  end

  test "the only executable a session spawns is the launcher, which execs the configured wrapper" do
    session = File.read!(Path.join(@root, "lib/loopctl_runner/session.ex"))
    assert session =~ "Port.open({:spawn_executable, launcher_script()}"

    # The launcher and the wrapper are what this canary pins; the argv is an argument, and it is
    # the one the CHECKED builder returned: bound once, from `argv/3`, and launched as is.
    assert session =~ "checked_argv = argv(story, session_id, opts)"
    assert length(Regex.scan(~r/\bchecked_argv\s*=[^=]/, session)) == 1
    assert session =~ "args: [stderr_log, config.claude_launcher | checked_argv]"

    launcher = File.read!(Path.join(@root, "priv/bin/session-launcher.sh"))
    assert launcher =~ ~s|"$headless" "$@" </dev/null|
  end
end
