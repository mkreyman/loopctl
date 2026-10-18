defmodule ChgAdapter do
  @moduledoc """
  Shared plumbing for the `mix chg.*` tasks (chg adapter contract v1,
  `docs/adapter-contract.md`).

  Every task prints exactly one JSON document as its last stdout line. Progress goes to
  stderr, or to stdout before the document, which `chg` relays to stderr.
  """

  @state_dir "_build/chg"

  @doc "Where the snapshot marker and the test reference cache live (cloned with `_build`)."
  def state_dir, do: @state_dir

  @doc """
  Loads every module of this archive, then compiles the project. `mix compile` prunes
  the code path to the project's own applications (`Mix.Tasks.Compile.All`), which
  removes the archive's ebin: a module not loaded before that is unloadable after it.
  """
  def preload_and_compile! do
    preload!()
    Mix.Task.run("compile")
  end

  def preload! do
    for app <- [:chg_adapter, :ex_unit] do
      _ = Application.load(app)
      {:ok, mods} = :application.get_key(app, :modules)
      Code.ensure_all_loaded!(mods)
    end

    :ok
  end

  @doc """
  Runs `fun` only under `MIX_ENV=test`. Mix 1.20 deprecates a task choosing its own env
  (`@preferred_cli_env`), and a product should not need a `def cli` entry for an
  archive's tasks, so a task started in another env runs itself again under
  `MIX_ENV=test`, passing its stdout through. The adapter manifest sets `MIX_ENV=test`
  on these commands, so `chg` never pays for the second VM.
  """
  def in_test_env(task, args, fun) do
    if Mix.env() == :test do
      fun.()
    else
      {_, status} =
        System.cmd("mix", [task | args],
          env: [{"MIX_ENV", "test"}],
          into: IO.stream(:stdio, :line)
        )

      halt(status)
    end
  end

  @doc "Prints the contract document as the last stdout line."
  def emit(doc), do: IO.puts(JSON.encode!(doc))

  @doc "Exits the task with `status` after the document is out."
  def halt(0), do: :ok
  def halt(status), do: exit({:shutdown, status})

  @doc "Runs a command with its output on stderr; returns the exit status."
  def stream(cmd, args, env \\ []) do
    {_, status} =
      System.cmd(cmd, args,
        env: env,
        into: IO.stream(:standard_error, :line),
        stderr_to_stdout: true
      )

    status
  end

  @doc """
  Runs a command and captures stdout, echoing it to stderr so a slow step still shows
  progress. The command's own stderr is merged in when `merge: true`.
  """
  def capture(cmd, args, opts \\ []) do
    {out, status} =
      System.cmd(cmd, args,
        env: Keyword.get(opts, :env, []),
        stderr_to_stdout: Keyword.get(opts, :merge, true)
      )

    IO.write(:standard_error, out)
    {out, status}
  end

  @doc """
  The commit the tree holds: `CHG_SHA` when chg sets it (a snapshot build runs in a plain
  tree with no `.git`), else git's HEAD.
  """
  def head! do
    case System.get_env("CHG_SHA") do
      sha when sha in [nil, ""] -> git!(["rev-parse", "HEAD"])
      sha -> sha
    end
  end

  @doc "Trimmed stdout of a git command that must succeed."
  def git!(args) do
    case System.cmd("git", args, stderr_to_stdout: true) do
      {out, 0} -> String.trim(out)
      {out, _} -> Mix.raise("git #{Enum.join(args, " ")} failed: #{String.trim(out)}")
    end
  end

  @doc """
  Paths that differ between `base` and the working tree, tracked or untracked, with
  renames split into the deleted and the added path, relative to the project directory
  and limited to it (`--relative`), as the manifest records them. The same set `chg`
  checks against `always_all`.
  """
  def changed_paths(base) do
    with {:ok, sha} <- resolve(base),
         {:ok, diff} <- git_z(["diff", "--relative", "--no-renames", "--name-only", "-z", sha]),
         {:ok, new} <- git_z(["ls-files", "--others", "--exclude-standard", "-z"]) do
      {:ok, Enum.uniq(diff ++ new)}
    end
  end

  def resolve(rev) do
    case System.cmd("git", ["rev-parse", "--verify", "--quiet", rev <> "^{commit}"],
           stderr_to_stdout: true
         ) do
      {sha, 0} -> {:ok, String.trim(sha)}
      _ -> {:error, "`#{rev}` is not a commit"}
    end
  end

  defp git_z(args) do
    case System.cmd("git", args, stderr_to_stdout: true) do
      {out, 0} -> {:ok, String.split(out, <<0>>, trim: true)}
      {out, _} -> {:error, "git #{hd(args)} failed: #{String.trim(out)}"}
    end
  end

  @doc "The project's test files, as `mix test` would load them."
  def test_files do
    for dir <- Mix.Project.config()[:test_paths] || ["test"],
        file <- Path.wildcard(Path.join(dir, "**/*.exs")),
        test_file?(file),
        do: file
  end

  @doc "True when `path` is a file `mix test` would load."
  def test_file?(path) do
    config = Mix.Project.config()
    filters = config[:test_load_filters] || [&String.ends_with?(&1, "_test.exs")]
    ignore = config[:test_ignore_filters] || []

    Enum.any?(config[:test_paths] || ["test"], &String.starts_with?(path, &1 <> "/")) and
      Enum.any?(filters, &match_filter?(&1, path)) and
      not Enum.any?(ignore, &match_filter?(&1, path))
  end

  @doc "True when `path` is under one of the project's test paths."
  def test_path?(path) do
    Enum.any?(
      Mix.Project.config()[:test_paths] || ["test"],
      &String.starts_with?(path, &1 <> "/")
    )
  end

  defp match_filter?(%Regex{} = r, file), do: Regex.match?(r, file)
  defp match_filter?(f, file) when is_function(f, 1), do: f.(file)

  @doc """
  The `MIX_ENV` to run a dependency's tasks in, from its declaration in `deps`, or nil
  when it is not a dependency: "test" unless `:only` leaves it out of test, then "dev",
  then the first env `:only` names. `{:dialyxir, "~> 1.4", only: :dev}` is common, and
  `MIX_ENV=test mix dialyzer` cannot find the task there.
  """
  def dep_env(name, deps \\ Mix.Project.config()[:deps] || []) do
    case Enum.find(deps, &(elem(&1, 0) == name)) do
      nil ->
        nil

      dep ->
        opts = dep |> Tuple.to_list() |> List.last()
        only = if Keyword.keyword?(opts), do: opts[:only], else: nil

        case List.wrap(only) do
          [] -> "test"
          envs -> Enum.find(["test", "dev"], &(String.to_atom(&1) in envs)) || to_string(hd(envs))
        end
    end
  end

  @doc "Writes `data` to `path` atomically: a reader sees the old file or the new one."
  def write_atomic!(path, data) do
    File.mkdir_p!(Path.dirname(path))
    tmp = "#{path}.#{System.os_time()}.tmp"
    File.write!(tmp, data)
    File.rename!(tmp, path)
  end

  @doc "Milliseconds since `started` (a `System.monotonic_time/0`)."
  def ms_since(started) do
    System.convert_time_unit(System.monotonic_time() - started, :native, :millisecond)
  end

  @doc "The last `n` lines of `text`, for a failure message."
  def tail(text, n \\ 40) do
    text |> String.split("\n") |> Enum.take(-n) |> Enum.join("\n") |> String.trim()
  end
end
