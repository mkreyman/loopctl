defmodule LoopctlRunner.TestSupport do
  @moduledoc false

  alias LoopctlRunner.Config

  @headless Path.expand("~/workspace/claude-config/bin/claude-headless.sh")

  def headless_launcher, do: @headless

  def fake_bin_dir, do: Path.expand("bin", __DIR__)

  def tmp_dir!(label) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "loopctl-runner-test-#{label}-#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    dir
  end

  def git_repo!(dir) do
    File.mkdir_p!(dir)
    git!(dir, ["init", "-q", "-b", "master"])
    git!(dir, ["config", "user.email", "test@example.com"])
    git!(dir, ["config", "user.name", "test"])
    git!(dir, ["config", "core.hooksPath", "/dev/null"])
    File.write!(Path.join(dir, "README.md"), "fixture\n")
    git!(dir, ["add", "README.md"])
    git!(dir, ["commit", "-q", "-m", "init"])
    dir
  end

  def git!(dir, args) do
    env = Enum.map(LoopctlRunner.Worktree.repo_locating_env(), &{&1, nil})
    {out, 0} = System.cmd("git", ["-C", dir | args], stderr_to_stdout: true, env: env)
    String.trim(out)
  end

  def config_map(root, overrides \\ %{}) do
    Map.merge(
      %{
        "runs_dir" => Path.join(root, "runs"),
        "claude_projects_dir" => Path.join(root, "projects"),
        "claude_launcher" => @headless,
        "repos" => %{"fixture" => Path.join(root, "repo")},
        "branch_prefixes" => ["loop/"],
        "max_wall_clock_s" => 60,
        "max_turns" => 10,
        "park_after_s" => 1,
        "liveness_interval_s" => 1,
        "kill_grace_s" => 2,
        "agents_probe_timeout_s" => 5
      },
      overrides
    )
  end

  def config!(root, overrides \\ %{}) do
    {:ok, config} = Config.from_map(config_map(root, overrides))
    config
  end

  def story_map(overrides \\ %{}) do
    Map.merge(
      %{
        "id" => "s1",
        "repo" => "fixture",
        "base" => "master",
        "branch" => "loop/s1",
        "prompt" => "do the thing",
        "wall_clock_s" => 30,
        "max_turns" => 5
      },
      overrides
    )
  end

  @doc "Sets the fake CLI's environment for the duration of a test."
  def fake_env!(state_dir, vars) do
    previous = System.get_env("PATH")
    System.put_env("PATH", fake_bin_dir() <> ":" <> previous)
    System.put_env("FAKE_STATE_DIR", state_dir)
    Enum.each(vars, fn {k, v} -> System.put_env(k, v) end)

    fn ->
      System.put_env("PATH", previous)
      Enum.each(["FAKE_STATE_DIR" | Enum.map(vars, &elem(&1, 0))], &System.delete_env/1)
    end
  end

  def os_pid_alive?(pid) do
    match?({_, 0}, System.cmd("kill", ["-0", "#{pid}"], stderr_to_stdout: true))
  end

  def wait_until(fun, timeout_ms \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait(fun, deadline)
  end

  defp do_wait(fun, deadline) do
    cond do
      fun.() -> :ok
      System.monotonic_time(:millisecond) > deadline -> :timeout
      true -> sleep_then_wait(fun, deadline)
    end
  end

  defp sleep_then_wait(fun, deadline) do
    Process.sleep(50)
    do_wait(fun, deadline)
  end

  def read_int!(path), do: path |> File.read!() |> String.trim() |> String.to_integer()
end
