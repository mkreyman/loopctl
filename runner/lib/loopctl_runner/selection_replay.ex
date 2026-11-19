defmodule LoopctlRunner.SelectionReplay do
  @moduledoc """
  The selection replay a `verify@1` run attaches to a `pass` on a pull request that changes chg's
  test-selection code (contract 1.32.0, `selection_replay`; loopctl US-51.5). loopctl merges such
  a change without a person only when this measurement shows that selection only WIDENED
  (`Loopctl.Changes.SelectionProof`), and it reads it from the verifier's own recorded verdict.

  ## The runner measures, never the session

  The replay is the RUNNER's command, run beside the verify session, and its output goes into the
  result unmodified. The session is not asked for it and cannot supply it:
  `LoopctlRunner.VerifyResult.complete/2` refuses any key of the session's beyond `verdict`,
  `findings` and `head_sha`. A session that read the implementer's code is the one party that
  must not be able to write the number that lets that code merge unreviewed.

  For the same reason the replay SCRIPT is read from the base (`origin/<base>`, through
  `LoopctlRunner.Worktree.commit_file/4`), never from the pull request's tree: a pull request
  that edits `bin/chg-replay-selection.py` would otherwise choose its own measurement. The script
  then builds chg at the merge base and at the head and compares what each selects over the
  product's recent commits (chg's `bin/chg-replay-selection.py` says how). Building and running
  the head's code is what the verify session does anyway when it runs the tests; this runs it as
  the runner's own command, under `LoopctlRunner.ProcessGroup.run/5`'s credential scrub.

  ## When it runs

  Only for a repository with an entry in the config's `selection_replay` (topology is
  configuration, never source), and only when the change from the merge base to the head
  touches a path one of the entry's `paths` globs matches, old names of deletions and renames
  included (`--no-renames` lists both sides). loopctl's own list of chg's effect paths lives in
  a Fly secret this runner cannot read, so the entry's list is the operator's copy of it, and
  both directions of drift fail safe: a path missing here sends a pass without a replay, which
  loopctl escalates to a person as before; a path added here costs a replay nobody reads.

  `product` names the entry's product checkout in `repos` (its deps fetched, as the script
  needs), and `corpus` (5..30, default 5: loopctl accepts no proof on fewer than 5 commits) how
  many of its commits are replayed.

  ## When it is used, and when it is stopped

  It starts with the session, so it spends the session's wall clock rather than adding to it:
  loopctl frees a dispatch's reservation once its wall clock and grace are spent, and a result
  sent after that is refused. It is bounded by the same stop the session is. Only a `pass` waits
  for it; a reject, or a run with no result, stops it at once, because loopctl reads the replay
  only beside a pass. A replay that fails, times out or prints something outside the schema is
  traced and left out: the pass is sent without it, and loopctl escalates the change to a person
  exactly as it does today. It never turns a pass into anything else.

  Its processes carry a marker of their own (`ProcessGroup.marker/1`), recorded in `state.json`
  before they start, and the group it leads is recorded with its leader's start once it starts,
  because on macOS the marker is invisible for Apple binaries. `LoopctlRunner.Reaper` ends both
  for a run whose BEAM died, and the run ends them itself on every way out (`terminate/2`). The
  session's own marker is not used: the session launcher's teardown would kill the replay with
  the session.

  Its result is its STDOUT alone, and exactly one line of it (`parse/1`); stderr goes to a file
  of its own in the run directory, read only to explain a failure.
  """

  alias LoopctlRunner.{
    AgentResult,
    AtomicFile,
    Contract,
    Owner,
    ProcessGroup,
    RunState,
    Session,
    Worktree
  }

  @script "bin/chg-replay-selection.py"
  @max_script_bytes 1_048_576
  @min_corpus 5
  @max_corpus 30
  @term_grace_ms 30_000
  # What answering takes once the replay's processes are gone: the task's reply and the result.
  @answer_slack_ms 5_000

  @type entry :: %{product: String.t(), paths: [String.t()], corpus: pos_integer()}

  @typedoc """
  A replay underway: its task, the instant it must be gone by, and how it is ended — the
  `state.json` entry `terminate/2` reads (its marker id, and the file its group is recorded in).
  """
  @type handle :: %{task: Task.t(), stop_at_ms: integer(), entry: %{String.t() => String.t()}}

  @doc "The script a replay runs, as its path in the base commit."
  @spec script() :: String.t()
  def script, do: @script

  @doc """
  The config's `selection_replay` object, validated: `{"<repo>": {"product": "<repo>", "paths":
  [globs], "corpus": n}}`, each repo and product a key of `repos`. Absent is `%{}`.
  """
  @spec from_config(map(), %{optional(String.t()) => String.t()}) ::
          {:ok, %{optional(String.t()) => entry()}} | {:error, String.t()}
  def from_config(map, repos) do
    case Map.get(map, "selection_replay", %{}) do
      entries when is_map(entries) ->
        Enum.reduce_while(entries, {:ok, %{}}, &add_entry(&1, &2, repos))

      _ ->
        {:error, "config selection_replay must be an object"}
    end
  end

  defp add_entry({repo, raw}, {:ok, acc}, repos) do
    case entry(repo, raw, repos) do
      {:ok, entry} -> {:cont, {:ok, Map.put(acc, repo, entry)}}
      {:error, _} = error -> {:halt, error}
    end
  end

  defp entry(repo, raw, repos) when is_map(raw) do
    where = "config selection_replay.#{repo}"
    corpus = Map.get(raw, "corpus", @min_corpus)

    cond do
      not Map.has_key?(repos, repo) ->
        {:error, "#{where} names a repo that is not in repos"}

      (extra = Map.keys(raw) -- ~w(product paths corpus)) != [] ->
        {:error, "#{where} carries unknown keys #{Enum.join(Enum.sort(extra), ", ")}"}

      not repo_name?(raw["product"], repos) ->
        {:error, "#{where}.product must name a repo in repos"}

      not globs?(raw["paths"]) ->
        {:error, "#{where}.paths must be a non-empty list of relative path globs"}

      not corpus?(corpus) ->
        {:error,
         "#{where}.corpus must be an integer from #{@min_corpus} to #{@max_corpus} " <>
           "(loopctl accepts no proof on fewer than #{@min_corpus} commits)"}

      true ->
        {:ok, %{product: raw["product"], paths: raw["paths"], corpus: corpus}}
    end
  end

  defp entry(repo, _raw, _repos),
    do: {:error, "config selection_replay.#{repo} must be an object"}

  defp repo_name?(name, repos), do: is_binary(name) and Map.has_key?(repos, name)
  defp globs?(paths), do: is_list(paths) and paths != [] and Enum.all?(paths, &glob?/1)
  defp corpus?(corpus), do: is_integer(corpus) and corpus in @min_corpus..@max_corpus

  defp glob?(pattern),
    do:
      is_binary(pattern) and pattern != "" and not String.starts_with?(pattern, "/") and
        not String.contains?(pattern, <<0>>)

  @doc """
  Whether `path` matches `pattern`: `**` any run of characters across directories (`a/**/b`
  includes `a/b`), `*` any run within one segment, `?` one character other than `/`, and
  everything else literally.
  """
  @spec glob_match?(String.t(), String.t()) :: boolean()
  def glob_match?(pattern, path), do: Regex.match?(glob_regex(pattern), path)

  defp glob_regex(pattern) do
    body =
      pattern
      |> String.split(~r/(\*\*\/|\*\*|\*|\?)/, include_captures: true, trim: true)
      |> Enum.map_join(fn
        "**/" -> "(?:.*/)?"
        "**" -> ".*"
        "*" -> "[^/]*"
        "?" -> "[^/]"
        literal -> Regex.escape(literal)
      end)

    Regex.compile!("\\A" <> body <> "\\z", "u")
  end

  @doc """
  What a verify run of `repo_name`'s pull request should replay, judged in `tree` (the
  checkout at the head) against `base`: `{:replay, plan}`, or `{:skip, reason}`. The plan
  carries the merge base, the head, the product's path and the corpus.
  """
  @spec plan(LoopctlRunner.Config.t(), String.t(), String.t(), String.t()) ::
          {:replay, map()} | {:skip, String.t()}
  def plan(config, repo_name, tree, base) do
    with {:ok, entry} <- configured(config, repo_name),
         {:ok, product} <- product(config, entry),
         {:ok, head} <- rev(tree, "HEAD"),
         {:ok, merge_base} <- merge_base(tree, "origin/" <> base),
         {:ok, touched} <- touched(tree, merge_base),
         {:ok, matched} <- matched(entry, touched) do
      {:replay,
       %{
         base: base,
         merge_base: merge_base,
         head: head,
         product: product,
         corpus: entry.corpus,
         matched: matched
       }}
    end
  end

  defp configured(config, repo_name) do
    case Map.fetch(config.selection_replay, repo_name) do
      {:ok, entry} -> {:ok, entry}
      :error -> {:skip, "#{repo_name} has no selection_replay entry"}
    end
  end

  defp product(config, entry) do
    path = Map.fetch!(config.repos, entry.product)

    if File.dir?(path),
      do: {:ok, path},
      else: {:skip, "the product checkout #{path} is not a directory"}
  end

  defp rev(tree, ref) do
    case Worktree.split_git("git", tree, ["rev-parse", "--verify", "--quiet", ref <> "^{commit}"]) do
      {:ok, sha} -> {:ok, String.trim(sha)}
      {:error, why} -> {:skip, "#{ref} does not resolve: #{why}"}
    end
  end

  defp merge_base(tree, ref) do
    case Worktree.split_git("git", tree, ["merge-base", ref, "HEAD"]) do
      {:ok, sha} when sha != "" -> {:ok, String.trim(sha)}
      {:ok, _} -> {:skip, "#{ref} and HEAD share no merge base"}
      {:error, why} -> {:skip, "no merge base of #{ref} and HEAD: #{why}"}
    end
  end

  defp touched(tree, merge_base) do
    args = ["diff", "--name-only", "-z", "--no-renames", merge_base, "HEAD"]

    case Worktree.split_git("git", tree, args) do
      {:ok, out} -> {:ok, String.split(out, <<0>>, trim: true)}
      {:error, why} -> {:skip, "the change's files could not be listed: #{why}"}
    end
  end

  defp matched(entry, touched) do
    case Enum.filter(touched, fn path -> Enum.any?(entry.paths, &glob_match?(&1, path)) end) do
      [] -> {:skip, "the change touches no selection path"}
      matched -> {:ok, matched}
    end
  end

  @doc """
  Starts `plan`'s replay for the checkout `repo_path` (chg's, the commits' home), with the
  script read from `origin/<base>` there. Records its marker in `run_dir`'s state before
  anything starts. `{:started, handle}`, or `{:skip, reason}` when it cannot start.

  Options: `:bound_ms` (required), by when from now every process of the replay must be gone,
  its TERM grace included; `:env`, the environment the release and git-locating names are
  judged from (default the runner's).
  """
  @spec start(map(), String.t(), String.t(), keyword()) ::
          {:started, handle()} | {:skip, String.t()}
  def start(plan, repo_path, run_dir, opts) do
    timeout_ms = Keyword.fetch!(opts, :bound_ms) - @term_grace_ms - @answer_slack_ms
    env = Keyword.get_lazy(opts, :env, &System.get_env/0)

    with :ok <- time_left(timeout_ms),
         {:ok, python} <- python(env),
         {:ok, script} <- write_script(repo_path, plan.base, run_dir) do
      marker_id = Session.uuid4()
      group_file = Path.join(run_dir, "selection-replay.group")
      stderr_file = Path.join(run_dir, "selection-replay.stderr")
      entry = %{"marker_id" => marker_id, "group_file" => group_file}
      RunState.update(run_dir, %{"selection_replay" => entry})

      argv = [
        "-I",
        script,
        "--chg",
        repo_path,
        "--base",
        plan.merge_base,
        "--head",
        plan.head,
        "--repo",
        plan.product,
        "--corpus",
        Integer.to_string(plan.corpus)
      ]

      run_opts = [
        term_grace_ms: @term_grace_ms,
        stderr_file: stderr_file,
        on_start: &record_group(group_file, &1)
      ]

      task =
        Task.async(fn ->
          execute(python, argv, timeout_ms, port_env(marker_id, env), run_opts)
        end)

      {:started,
       %{task: task, entry: entry, stop_at_ms: System.monotonic_time(:millisecond) + timeout_ms}}
    end
  end

  defp time_left(timeout_ms) when timeout_ms > 0, do: :ok
  defp time_left(_timeout_ms), do: {:skip, "the session's time leaves no room for a replay"}

  defp python(env) do
    path = env |> Session.release_path() |> Map.new() |> Map.get("PATH", env["PATH"])

    case find_on(path, "python3") do
      nil -> {:skip, "python3 is not on PATH"}
      found -> {:ok, found}
    end
  end

  # The release's own PATH entries are not searched, as a session's are not.
  defp find_on(nil, _name), do: nil

  defp find_on(path, name) do
    path
    |> String.split(":", trim: true)
    |> Enum.map(&Path.join(&1, name))
    |> Enum.find(&executable?/1)
  end

  defp executable?(file) do
    case File.stat(file) do
      {:ok, %File.Stat{type: :regular, mode: mode}} -> Bitwise.band(mode, 0o111) != 0
      _ -> false
    end
  end

  defp write_script(repo_path, base, run_dir) do
    ref = "origin/" <> base

    case Worktree.commit_file(repo_path, ref, @script, @max_script_bytes) do
      {:ok, text} ->
        file = Path.join(run_dir, "selection-replay.py")
        File.write!(file, text)
        {:ok, file}

      :absent ->
        {:skip, "#{ref} has no #{@script}"}

      {:error, why} ->
        {:skip, "#{@script} could not be read from #{ref}: #{why}"}
    end
  end

  # The runner's own command, so `ProcessGroup.run/5`'s credential scrub applies; on top of it the
  # release's own environment is taken out, as a session's is, so `mix` and `erl` are the
  # machine's and not the release's, and the variables that point git elsewhere are unset.
  defp port_env(marker_id, env) do
    [{"LOOP_SESSION_ID", marker_id}] ++
      Session.release_path(env) ++
      Enum.map(Session.release_env(env) ++ Worktree.repo_locating_env(), &{&1, nil})
  end

  # The group the replay leads (`run_group/5` makes it a session leader), with its start, so a
  # later reader never signals a pid recycled into a stranger's group. On macOS the marker is
  # invisible for Apple binaries (`/usr/bin/python3`, git, the linker), so the group is what ends
  # them. Never raises: a group left unrecorded still leaves the marker.
  defp record_group(group_file, pgid) do
    AtomicFile.write!(group_file, "#{pgid} #{Owner.start_id(pgid) || ""}\n")
  rescue
    _ -> :ok
  end

  # Never raises and never exits abnormally: the task is linked to the run.
  defp execute(python, argv, timeout_ms, env, run_opts) do
    case ProcessGroup.run_group(python, argv, timeout_ms, env, run_opts) do
      {:ok, out, 0} -> parse(out)
      {:ok, _out, status} -> {:error, "the replay exited #{status}: #{stderr_tail(run_opts)}"}
      {:error, :timeout} -> {:error, "the replay did not finish in #{div(timeout_ms, 1000)}s"}
    end
  rescue
    error -> {:error, "the replay could not run: #{Exception.message(error)}"}
  catch
    kind, reason -> {:error, "the replay could not run: #{Exception.format_banner(kind, reason)}"}
  end

  defp stderr_tail(run_opts) do
    case File.read(run_opts[:stderr_file]) do
      {:ok, text} -> text |> String.trim() |> String.slice(-500, 500)
      {:error, _} -> "(no stderr)"
    end
  end

  @doc """
  The `selection_replay` object the replay's STDOUT holds, decoded and judged against verify@1's
  schema for the field. The script prints exactly one line there (its diagnostics go to stderr,
  which is a file of its own, and every build it runs is captured), so anything else on stdout —
  a second line from a process of the head's code that reached the stream — refuses the
  measurement rather than letting the last writer choose it.
  """
  @spec parse(binary()) :: {:ok, map()} | {:error, String.t()}
  def parse(output) do
    lines =
      output
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    with {:ok, line} <- one_line(lines),
         {:ok, %{} = replay} <- decode(line),
         :ok <- valid(replay) do
      {:ok, replay}
    end
  end

  defp one_line([]), do: {:error, "the replay printed nothing"}
  defp one_line([line]), do: {:ok, line}

  defp one_line(lines),
    do: {:error, "the replay printed #{length(lines)} lines on stdout, not one; nothing is sent"}

  defp decode(line) do
    case JSON.decode(line) do
      {:ok, %{} = replay} -> {:ok, replay}
      _ -> {:error, "the replay's last line is not a JSON object: #{String.slice(line, 0, 200)}"}
    end
  end

  defp valid(replay) do
    {:ok, schema} = AgentResult.schema({"verify", 1})
    field = get_in(schema, ["properties", "selection_replay"])

    case Contract.validate_against(field, replay, "selection_replay") do
      :ok -> :ok
      {:error, errors} -> {:error, "the replay fails the schema: " <> Enum.join(errors, "; ")}
    end
  end

  @doc """
  The replay's answer, waiting for it no later than its own stop plus the TERM grace:
  `{:ok, replay}` or `{:error, reason}`.
  """
  @spec await(handle()) :: {:ok, map()} | {:error, String.t()}
  def await(%{task: task, stop_at_ms: stop_at_ms}) do
    wait_ms =
      max(stop_at_ms - System.monotonic_time(:millisecond), 0) + @term_grace_ms + @answer_slack_ms

    case Task.yield(task, wait_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      {:exit, reason} -> {:error, "the replay's task exited: #{inspect(reason)}"}
      nil -> {:error, "the replay did not answer in time"}
    end
  end

  @doc """
  Ends the replay, whatever state it is in: its processes, then its task. Safe to call after
  `await/1`.
  """
  @spec stop(handle(), non_neg_integer()) :: ProcessGroup.outcome()
  def stop(%{task: task, entry: entry}, grace_ms) do
    outcome = terminate(entry, grace_ms)
    Task.shutdown(task, :brutal_kill)
    outcome
  end

  @doc """
  Ends every process of the replay `entry` (its `state.json` record) names: its group, while the
  recorded leader is still the one that started, and every process carrying its marker. Used by
  `stop/2` and by `LoopctlRunner.Reaper` for a run whose BEAM died.
  """
  @spec terminate(map(), non_neg_integer()) :: ProcessGroup.outcome()
  def terminate(%{"marker_id" => marker_id} = entry, grace_ms) when is_binary(marker_id) do
    {pgid, start_id} = recorded_group(entry["group_file"])

    ProcessGroup.terminate(pgid, grace_ms,
      marker: ProcessGroup.marker(marker_id),
      leader_start_id: start_id
    )
  end

  # A group is signalled only with the start it was recorded with: without one, a pid that has
  # since been recycled could not be told from the replay's.
  defp recorded_group(file) when is_binary(file) do
    with {:ok, raw} <- File.read(file),
         [pgid_s, start_id] <- String.split(String.trim(raw), " ", parts: 2),
         {pgid, ""} when pgid > 1 <- Integer.parse(pgid_s),
         true <- start_id != "" do
      {pgid, start_id}
    else
      _ -> {nil, nil}
    end
  end

  defp recorded_group(_file), do: {nil, nil}
end
