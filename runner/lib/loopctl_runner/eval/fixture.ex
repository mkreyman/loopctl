defmodule LoopctlRunner.Eval.Fixture do
  @moduledoc """
  The repositories an eval case runs against (US-48.10): tiny, synthetic, and never a real one.

  A fixture is a JSON MANIFEST under `eval/fixtures/` that builds a git repository
  deterministically — its commits' files, messages, author and dates — so the same manifest
  produces the same commit shas on every machine. The manifest names the sha its last commit must
  come out as (`head`), and a build that produces anything else is refused: a fixture whose
  history moved under the cases pinned to it would make every recorded result incomparable with
  the last.

      {"name": "tiny_app", "branch": "master",
       "author": {"name": "...", "email": "..."},
       "commits": [{"message": "...", "date": "2026-01-01T00:00:00Z", "files": {"path": "text"}}],
       "head": "<40-hex sha>"}

  Git runs with the operator's global and system config switched off (`GIT_CONFIG_GLOBAL`,
  `GIT_CONFIG_NOSYSTEM`), no hooks and no signing, and without the variables that point git at
  another repository (`LoopctlRunner.Worktree.repo_locating_env/0`): any of them would change
  the bytes of a commit, and so its sha.

  ## AC-48.10.5: the eval never reaches a production repository

  `resolve/3` is the guard. A case's `fixture.repo` resolves inside the eval directory's
  `fixtures/` or inside the run's scratch directory, or the case is refused before anything runs;
  a symlink on the way is refused too, because a link inside `fixtures/` to a real checkout is
  exactly the path the prefix check alone would let through. Every repository a case's session
  touches is then a clone OF the built fixture, inside the scratch directory: the bare `origin`
  a `:build` run fetches from and pushes to, and the checkout the runner cuts its worktree from.
  """

  @sha ~r/\A[0-9a-f]{40}\z/
  @name ~r/\A[a-z][a-z0-9_]{0,63}\z/

  @type built :: %{name: String.t(), path: String.t(), branch: String.t(), head: String.t()}

  @doc """
  The manifest path a case's `fixture.repo` names, resolved against `eval_dir`, when it lies
  inside `eval_dir/fixtures` or `scratch_dir` with no symlink on the way; otherwise the refusal.
  """
  @spec resolve(String.t(), String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def resolve(repo, eval_dir, scratch_dir) when is_binary(repo) do
    path = Path.expand(repo, eval_dir)
    roots = [Path.join(Path.expand(eval_dir), "fixtures"), Path.expand(scratch_dir)]

    case Enum.find(roots, &inside?(path, &1)) do
      nil ->
        {:error,
         "fixture #{repo} resolves to #{path}, outside #{Enum.join(roots, " and ")}: " <>
           "an eval case runs only against a fixture repository"}

      root ->
        no_symlink(path, root)
    end
  end

  defp inside?(path, root), do: String.starts_with?(path, root <> "/")

  # Every component below the root is checked with lstat, the root itself too: a link anywhere
  # on the way is a way out of it.
  defp no_symlink(path, root) do
    parts = path |> Path.relative_to(root) |> Path.split()

    walked =
      Enum.reduce_while(parts, {:ok, root}, fn part, {:ok, at} ->
        next = Path.join(at, part)

        case File.lstat(next) do
          {:ok, %File.Stat{type: :symlink}} -> {:halt, {:error, next}}
          _ -> {:cont, {:ok, next}}
        end
      end)

    case {File.lstat(root), walked} do
      {{:ok, %File.Stat{type: :symlink}}, _} ->
        {:error, "fixture root #{root} is a symlink: an eval case runs only against a fixture"}

      {_, {:error, link}} ->
        {:error, "fixture path #{link} is a symlink: an eval case runs only against a fixture"}

      {_, {:ok, _}} ->
        {:ok, path}
    end
  end

  @doc "Reads and checks a fixture manifest."
  @spec load(String.t()) :: {:ok, map()} | {:error, String.t()}
  def load(path) do
    with {:ok, raw} <- read(path),
         {:ok, manifest} <- decode(raw, path) do
      check(manifest, path)
    end
  end

  defp read(path) do
    case File.read(path) do
      {:ok, raw} -> {:ok, raw}
      {:error, reason} -> {:error, "fixture #{path}: #{:file.format_error(reason)}"}
    end
  end

  defp decode(raw, path) do
    case Jason.decode(raw) do
      {:ok, %{} = manifest} -> {:ok, manifest}
      _ -> {:error, "fixture #{path} is not a JSON object"}
    end
  end

  defp check(manifest, path) do
    cond do
      not matches?(manifest["name"], @name) ->
        {:error, "fixture #{path}: name must match #{Regex.source(@name)}"}

      not matches?(manifest["head"], @sha) ->
        {:error, "fixture #{path}: head must be a 40-hex commit sha"}

      not matches?(manifest["branch"], @name) ->
        {:error, "fixture #{path}: branch must match #{Regex.source(@name)}"}

      not author?(manifest["author"]) ->
        {:error, "fixture #{path}: author must carry a name and an email"}

      not commits?(manifest["commits"]) ->
        {:error, "fixture #{path}: commits must be a non-empty list of {message, date, files}"}

      true ->
        {:ok, manifest}
    end
  end

  defp matches?(value, regex), do: is_binary(value) and value =~ regex

  defp author?(%{"name" => name, "email" => email}) when is_binary(name) and is_binary(email),
    do: name != "" and email != ""

  defp author?(_), do: false

  defp commits?([_ | _] = commits), do: Enum.all?(commits, &commit?/1)
  defp commits?(_), do: false

  defp commit?(%{"message" => message, "date" => date, "files" => files})
       when is_binary(message) and is_binary(date) and is_map(files) do
    message != "" and match?({:ok, _, _}, DateTime.from_iso8601(date)) and
      Enum.all?(files, fn {file, text} -> safe_file?(file) and is_binary(text) end)
  end

  defp commit?(_), do: false

  # A relative path that stays inside the repository it is written to.
  defp safe_file?(file) when is_binary(file) do
    file != "" and Path.type(file) == :relative and
      not Enum.any?(Path.split(file), &(&1 in ["..", ".git"]))
  end

  @doc """
  Builds `manifest` into `dir` (which must not exist) and checks its head against the manifest's.
  """
  @spec build(map(), String.t()) :: {:ok, built()} | {:error, String.t()}
  def build(manifest, dir) do
    if File.exists?(dir) do
      {:error, "fixture build directory #{dir} already exists"}
    else
      File.mkdir_p!(dir)
      git!(dir, ["init", "-q", "-b", manifest["branch"]])
      Enum.each(manifest["commits"], &commit!(dir, manifest["author"], &1))
      head = git!(dir, ["rev-parse", "HEAD"])

      if head == manifest["head"],
        do: {:ok, %{name: manifest["name"], path: dir, branch: manifest["branch"], head: head}},
        else:
          {:error,
           "fixture #{manifest["name"]} built to #{head}, not the pinned #{manifest["head"]}: " <>
             "its manifest changed, or git wrote the commits differently on this machine"}
    end
  end

  defp commit!(dir, author, %{"message" => message, "date" => date, "files" => files}) do
    for {file, text} <- files do
      target = Path.join(dir, file)
      File.mkdir_p!(Path.dirname(target))
      File.write!(target, text)
    end

    git!(dir, ["add", "-A"])

    identity = [
      {"GIT_AUTHOR_NAME", author["name"]},
      {"GIT_AUTHOR_EMAIL", author["email"]},
      {"GIT_AUTHOR_DATE", date},
      {"GIT_COMMITTER_NAME", author["name"]},
      {"GIT_COMMITTER_EMAIL", author["email"]},
      {"GIT_COMMITTER_DATE", date}
    ]

    git!(dir, ["commit", "-q", "--no-verify", "-m", message], identity)
  end

  @doc """
  The checkout a case runs in, at `commit`, under `case_dir`: a bare `origin.git` cloned from the
  built fixture with `base` moved to `commit`, and a clone of THAT named `repo_name`, whose HEAD is
  `commit`. A `:build` run fetches its base from that origin, so the pin holds for it too.
  """
  @spec checkout(built(), String.t(), String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, String.t()}
  def checkout(built, commit, base, repo_name, case_dir) do
    origin = Path.join(case_dir, "origin.git")
    clone = Path.join(case_dir, repo_name)

    with :ok <- reachable(built, commit) do
      git!(case_dir, ["clone", "-q", "--bare", built.path, origin], [], false)
      git!(origin, ["update-ref", "refs/heads/#{base}", commit])
      git!(origin, ["symbolic-ref", "HEAD", "refs/heads/#{base}"])
      git!(case_dir, ["clone", "-q", origin, clone], [], false)
      git!(clone, ["config", "user.name", "loopctl-runner eval"])
      git!(clone, ["config", "user.email", "eval@example.invalid"])

      case git!(clone, ["rev-parse", "HEAD"]) do
        ^commit -> {:ok, clone}
        other -> {:error, "the case checkout is at #{other}, not the pinned #{commit}"}
      end
    end
  end

  defp reachable(built, commit) do
    case git(built.path, ["merge-base", "--is-ancestor", commit, built.head]) do
      {_, 0} ->
        :ok

      _ ->
        {:error, "pinned commit #{commit} is not in fixture #{built.name}'s history"}
    end
  end

  # Isolated from the operator's git: no global or system config, no hooks, no signing, and none
  # of the variables that redirect git to another repository.
  defp env(extra) do
    Enum.map(LoopctlRunner.Worktree.repo_locating_env(), &{&1, nil}) ++
      [{"GIT_CONFIG_GLOBAL", "/dev/null"}, {"GIT_CONFIG_NOSYSTEM", "1"}] ++ extra
  end

  defp git(dir, args, extra \\ [], in_repo \\ true) do
    args =
      ["-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false"] ++
        if(in_repo, do: ["-C", dir], else: []) ++ args

    opts = [stderr_to_stdout: true, env: env(extra)]
    opts = if in_repo, do: opts, else: Keyword.put(opts, :cd, dir)
    System.cmd("git", args, opts)
  end

  defp git!(dir, args, extra \\ [], in_repo \\ true) do
    case git(dir, args, extra, in_repo) do
      {out, 0} -> String.trim(out)
      {out, status} -> raise "git #{Enum.join(args, " ")} exited #{status}: #{String.trim(out)}"
    end
  end
end
