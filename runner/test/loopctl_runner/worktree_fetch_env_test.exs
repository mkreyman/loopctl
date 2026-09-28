defmodule LoopctlRunner.WorktreeFetchEnvTest do
  # Sets GIT_SSH_COMMAND in the OS environment, which every spawned process inherits.
  use ExUnit.Case, async: false

  alias LoopctlRunner.Worktree
  import LoopctlRunner.TestSupport

  # The runner fetches for itself, with no one to answer a prompt: an ssh passphrase or host-key
  # question, or a credential helper, must fail rather than wait on a terminal.
  test "runs with stdin from /dev/null, git's prompt off, and the configured ssh in BatchMode" do
    repo = git_repo!(Path.join(tmp_dir!("fetch-batch"), "repo"))
    {ssh, record} = recording_ssh!(Path.dirname(repo))
    git!(repo, ["remote", "add", "origin", "ssh://git@example.invalid/x.git"])
    git!(repo, ["config", "core.sshCommand", ssh <> " -i the-operators-key"])

    # The operator's own GIT_SSH_COMMAND outranks core.sshCommand, so it must not be set here.
    saved = System.get_env("GIT_SSH_COMMAND")
    System.delete_env("GIT_SSH_COMMAND")

    try do
      assert {:error, _} = Worktree.fetch_base(repo, "master")
    after
      if saved, do: System.put_env("GIT_SSH_COMMAND", saved)
    end

    seen = File.read!(record)
    # The operator's own command and options survive; BatchMode is added after them.
    assert seen =~ ~r/^args=-i the-operators-key -o BatchMode=yes /m
    assert seen =~ ~r/^prompt=0$/m
    assert seen =~ ~r|^stdin=/dev/null$|m
  end

  test "an operator's GIT_SSH_COMMAND is kept and put in BatchMode, not replaced" do
    repo = git_repo!(Path.join(tmp_dir!("fetch-env"), "repo"))
    {ssh, record} = recording_ssh!(Path.dirname(repo))
    git!(repo, ["remote", "add", "origin", "ssh://git@example.invalid/x.git"])
    # Outranked by the environment, as git ranks them: this must not be what runs.
    git!(repo, ["config", "core.sshCommand", "false"])

    saved = System.get_env("GIT_SSH_COMMAND")
    System.put_env("GIT_SSH_COMMAND", ssh <> " -o IdentitiesOnly=yes")

    try do
      assert {:error, _} = Worktree.fetch_base(repo, "master")
    after
      if saved,
        do: System.put_env("GIT_SSH_COMMAND", saved),
        else: System.delete_env("GIT_SSH_COMMAND")
    end

    assert File.read!(record) =~ ~r/^args=-o IdentitiesOnly=yes -o BatchMode=yes /m
  end

  test "the runner's own fetch keeps the operator's ssh agent, which the runner's scrub names" do
    # ProcessGroup.run/5 unsets credentials for the runner's own commands, and that list names the
    # agent socket. This fetch is the runner authenticating as the operator: under BatchMode a key
    # reachable only through the agent would fail every fetch without it. Presence only, never a
    # value: the recorded line says whether the name arrived.
    repo = git_repo!(Path.join(tmp_dir!("fetch-agent"), "repo"))
    dir = Path.dirname(repo)
    record = Path.join(dir, "agent-record")
    ssh = Path.join(dir, "agent-ssh")

    File.write!(ssh, """
    #!/bin/sh
    printf '%s\\n' "sock=${SSH_AUTH_SOCK+set}" > #{record}
    exit 1
    """)

    File.chmod!(ssh, 0o755)
    git!(repo, ["remote", "add", "origin", "ssh://git@example.invalid/x.git"])
    git!(repo, ["config", "core.sshCommand", ssh])

    saved = System.get_env("SSH_AUTH_SOCK")
    saved_command = System.get_env("GIT_SSH_COMMAND")
    System.put_env("SSH_AUTH_SOCK", "/tmp/not-a-real-agent-socket")
    # core.sshCommand is what must run, and the environment's command outranks it.
    System.delete_env("GIT_SSH_COMMAND")

    try do
      assert {:error, _} = Worktree.fetch_base(repo, "master")
    after
      if saved,
        do: System.put_env("SSH_AUTH_SOCK", saved),
        else: System.delete_env("SSH_AUTH_SOCK")

      if saved_command, do: System.put_env("GIT_SSH_COMMAND", saved_command)
    end

    assert File.read!(record) == "sock=set\n"
  end

  describe "an askpass program" do
    # Git runs one for an HTTP credential even with its terminal prompt off (measured, git 2.50),
    # and an askpass is typically a GUI dialog: the runner's fetch would wait on it for the whole
    # timeout, or hand it a credential nobody meant for this fetch. Origin here answers 401.
    setup do
      repo = git_repo!(Path.join(tmp_dir!("fetch-askpass"), "repo"))
      dir = Path.dirname(repo)
      asked = Path.join(dir, "asked")
      askpass = Path.join(dir, "askpass")
      File.write!(askpass, "#!/bin/sh\ntouch #{asked}\necho x\n")
      File.chmod!(askpass, 0o755)
      git!(repo, ["remote", "add", "origin", "http://127.0.0.1:#{unauthorized_http!()}/x.git"])
      # No operator credential helper answers for this test's origin.
      git!(repo, ["config", "credential.helper", ""])

      saved = Enum.map(~w(GIT_ASKPASS SSH_ASKPASS), &{&1, System.get_env(&1)})
      Enum.each(saved, fn {name, _} -> System.delete_env(name) end)

      on_exit(fn ->
        Enum.each(saved, fn
          {name, nil} -> System.delete_env(name)
          {name, value} -> System.put_env(name, value)
        end)
      end)

      {:ok, repo: repo, askpass: askpass, asked: asked}
    end

    # Git names why it could not ask: its terminal prompt is off, or, where git reads
    # `credential.interactive`, that it may not interact at all.
    test "configured as core.askPass is not run", ctx do
      git!(ctx.repo, ["config", "core.askPass", ctx.askpass])

      assert {:error, error} = Worktree.fetch_base(ctx.repo, "master")
      assert error =~ ~r/terminal prompts disabled|unable to get password/
      refute File.exists?(ctx.asked)
    end

    test "in the operator's GIT_ASKPASS is not run", ctx do
      System.put_env("GIT_ASKPASS", ctx.askpass)

      assert {:error, error} = Worktree.fetch_base(ctx.repo, "master")
      assert error =~ ~r/terminal prompts disabled|unable to get password/
      refute File.exists?(ctx.asked)
    end

    test "a credential helper is told not to interact, and gets the operator's forge token",
         ctx do
      # A helper still runs, and Git Credential Manager opens a window unless told not to. `gh`'s
      # helper authenticates with GH_TOKEN or GITHUB_TOKEN, which the runner's scrub names. Presence
      # only, never a value: the recorded lines say whether each name arrived.
      record = Path.join(Path.dirname(ctx.repo), "helper-record")
      helper = Path.join(Path.dirname(ctx.repo), "helper")

      File.write!(helper, """
      #!/bin/sh
      {
        echo "interactive=$(git config --get credential.interactive)"
        echo "gcm=${GCM_INTERACTIVE-unset}"
        echo "gh=${GH_TOKEN+set}"
        echo "github=${GITHUB_TOKEN+set}"
      } > #{record}
      """)

      File.chmod!(helper, 0o755)
      git!(ctx.repo, ["config", "--add", "credential.helper", "!" <> helper])
      saved = Enum.map(~w(GH_TOKEN GITHUB_TOKEN), &{&1, System.get_env(&1)})
      Enum.each(saved, fn {name, _} -> System.put_env(name, "not-a-real-token") end)

      try do
        assert {:error, _} = Worktree.fetch_base(ctx.repo, "master")
      after
        Enum.each(saved, fn
          {name, nil} -> System.delete_env(name)
          {name, value} -> System.put_env(name, value)
        end)
      end

      assert File.read!(record) == "interactive=false\ngcm=never\ngh=set\ngithub=set\n"
    end
  end

  # An HTTP server on loopback that answers every request 401, asking for Basic credentials. It
  # lives as long as the test: the listening socket closes with the process that opened it.
  defp unauthorized_http! do
    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    spawn_link(fn -> serve_unauthorized(listen) end)
    {:ok, port} = :inet.port(listen)
    port
  end

  defp serve_unauthorized(listen) do
    case :gen_tcp.accept(listen) do
      {:ok, socket} ->
        _ = read_request(socket, "")

        :gen_tcp.send(
          socket,
          "HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Basic realm=\"x\"\r\n" <>
            "Content-Length: 0\r\nConnection: close\r\n\r\n"
        )

        :gen_tcp.close(socket)
        serve_unauthorized(listen)

      {:error, _} ->
        :ok
    end
  end

  defp read_request(socket, acc) do
    if String.contains?(acc, "\r\n\r\n") do
      acc
    else
      case :gen_tcp.recv(socket, 0, 5_000) do
        {:ok, data} -> read_request(socket, acc <> data)
        {:error, _} -> acc
      end
    end
  end
end
