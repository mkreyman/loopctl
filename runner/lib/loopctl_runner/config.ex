defmodule LoopctlRunner.Config do
  @moduledoc """
  The runner's local configuration: machine topology and the dispatch allow-list.

  Topology never lives in source (design §13). The file is JSON, by default
  `~/.config/loopctl-runner/runner.json`, and `config/runner.example.json` documents it.

  Loading FAILS CLOSED (design §5 and §7): a missing, empty, unparseable or incomplete
  file is an error, never a default allow-list. A runner that cannot read its allow-list
  refuses every dispatch.
  """

  require Logger

  @default_path "~/.config/loopctl-runner/runner.json"

  @enforce_keys [:runs_dir, :claude_launcher, :claude_projects_dir, :repos, :branch_prefixes]
  defstruct [
    :runs_dir,
    :claude_launcher,
    :claude_projects_dir,
    :repos,
    :branch_prefixes,
    session_env: %{},
    # WHERE THE SUBAGENT GIT GRANTS LIVE, as data rather than as a call to `System.user_home!/0`
    # buried in `Run.execute/3`. It is here because the SUITE exercises the production path: with
    # the directory hardcoded there, every test that ran a Run swept the operator's real
    # ~/.claude, and a stamped grant planted there from outside the suite was deleted by a full
    # run (measured 2026-09-16). A test's config points at a directory the test owns; nothing a
    # test can call reaches the real one by default.
    grant_dir: nil,
    control: nil,
    max_wall_clock_s: 3600,
    max_turns: 200,
    park_after_s: 600,
    liveness_interval_s: 30,
    kill_grace_s: 10,
    agents_probe_timeout_s: 20,
    tree_poll_s: 1
  ]

  @type t :: %__MODULE__{
          runs_dir: String.t(),
          claude_launcher: String.t(),
          claude_projects_dir: String.t(),
          repos: %{optional(String.t()) => String.t()},
          branch_prefixes: [String.t()],
          session_env: %{optional(String.t()) => %{optional(String.t()) => String.t()}},
          grant_dir: String.t() | nil,
          control: LoopctlRunner.ControlConfig.t() | nil,
          max_wall_clock_s: pos_integer(),
          max_turns: pos_integer(),
          park_after_s: pos_integer(),
          liveness_interval_s: pos_integer(),
          kill_grace_s: pos_integer(),
          agents_probe_timeout_s: pos_integer(),
          tree_poll_s: pos_integer()
        }

  @positive_ints [
    :max_wall_clock_s,
    :max_turns,
    :park_after_s,
    :liveness_interval_s,
    :kill_grace_s,
    :agents_probe_timeout_s,
    :tree_poll_s
  ]

  @launcher_basename "claude-headless.sh"
  @launcher_marker "unset ANTHROPIC_API_KEY"

  @spec default_path() :: String.t()
  def default_path, do: Path.expand(@default_path)

  @doc """
  The directory the operator's subagent git grants live in — where `block-subagent-git.sh` looks,
  and what a config without `grant_dir` gets — or nil when the runner has no home directory.
  """
  @spec default_grant_dir() :: String.t() | nil
  def default_grant_dir do
    with home when is_binary(home) <- System.user_home(), do: Path.join(home, ".claude")
  end

  @doc "Reads and validates the config file at `path`."
  @spec load(String.t()) :: {:ok, t()} | {:error, String.t()}
  def load(path) do
    with {:ok, raw} <- read(path),
         {:ok, map} <- decode(raw),
         {:ok, config} <- from_map(map),
         :ok <- readable_by_owner_only(path, config) do
      warn_obsolete(map, path)
      {:ok, config}
    end
  end

  # An earlier release read `allowed_tools` as the permission rules a story could request; nothing
  # composes `--allowedTools` now, so the key grants nothing. Loading still succeeds, because
  # configs already on the dev machines carry it, and refusing them would stop those daemons over a
  # key that no longer does anything.
  defp warn_obsolete(map, path) do
    if Map.has_key?(map, "allowed_tools"),
      do: Logger.warning("config #{path}: allowed_tools is obsolete and ignored; remove it")
  end

  @doc """
  Warns when `config`'s grant_dir is not the directory `block-subagent-git.sh` reads (`default`,
  `default_grant_dir/0`). A grant_dir is config data so a TEST can point it elsewhere; an operator
  config that does the same arms grants the hook never sees, so every dispatched agent's commit is
  refused while the runner looks healthy.

  Called by every entry point that arms grants for real — the daemon
  (`LoopctlRunner.Application.daemon_children!/0`) and `mix loopctl.run` — and NOT by `load/1`,
  which every test config passes through with a directory of its own, and `mix loopctl.reap`,
  which arms nothing. The same directory reached another way — a symlinked HOME — is the same
  directory: compared by device and inode once the paths differ.
  """
  @spec warn_if_hook_cannot_see_grants(t(), String.t() | nil) :: :ok
  def warn_if_hook_cannot_see_grants(%__MODULE__{grant_dir: dir}, default \\ default_grant_dir()) do
    unless same_dir?(dir, default) do
      Logger.warning(
        "config grant_dir #{dir} is not #{default || "$HOME/.claude"}: block-subagent-git.sh " <>
          "reads grants only from $HOME/.claude, so the grants this runner arms there are " <>
          "invisible to it and a dispatched agent's commit will be refused"
      )
    end

    :ok
  end

  defp same_dir?(a, b) when is_binary(a) and is_binary(b) do
    Path.expand(a) == Path.expand(b) or same_file?(File.stat(a), File.stat(b))
  end

  defp same_dir?(_a, _b), do: false

  defp same_file?(
         {:ok, %File.Stat{major_device: device, inode: inode}},
         {:ok, %File.Stat{major_device: device, inode: inode}}
       ),
       do: true

  defp same_file?(_a, _b), do: false

  # `session_env` is where a repo's credential for its sessions goes (a test secret, a sandbox
  # key), which is only sound in a file only the operator can read. Nothing made that true: under
  # a default umask `runner.json` is 0644, so a real credential would sit in a world-readable file
  # on a machine carrying live credentials already. Same
  # test as `ControlConfig.read_token/1` uses for the channel token, and checked only when
  # `session_env` carries something: a config without it holds no secret of its own, and refusing
  # one would stop daemons over a property they never relied on.
  defp readable_by_owner_only(_path, %__MODULE__{session_env: env}) when map_size(env) == 0,
    do: :ok

  defp readable_by_owner_only(path, _config) do
    case File.stat(path) do
      {:ok, %File.Stat{mode: mode}} ->
        if Bitwise.band(mode, 0o077) == 0,
          do: :ok,
          else:
            {:error,
             "config #{path} carries session_env, which may hold a credential, and is readable " <>
               "by other users; chmod 600 it"}

      {:error, reason} ->
        {:error, "cannot stat config #{path}: #{:file.format_error(reason)}"}
    end
  end

  @doc "Validates an already-decoded config map."
  @spec from_map(map()) :: {:ok, t()} | {:error, String.t()}
  def from_map(map) when is_map(map) do
    with {:ok, runs_dir} <- required_path(map, "runs_dir"),
         {:ok, projects_dir} <- required_path(map, "claude_projects_dir"),
         {:ok, launcher} <- launcher(map),
         {:ok, repos} <- repos(map),
         {:ok, prefixes} <- branch_prefixes(map),
         {:ok, session_env} <- session_env(map, repos),
         {:ok, control} <- control(map),
         {:ok, grant_dir} <- grant_dir(map),
         {:ok, ints} <- positive_ints(map) do
      {:ok,
       struct!(
         __MODULE__,
         [
           runs_dir: runs_dir,
           claude_projects_dir: projects_dir,
           claude_launcher: launcher,
           repos: repos,
           branch_prefixes: prefixes,
           session_env: session_env,
           control: control,
           grant_dir: grant_dir
         ] ++ ints
       )}
    end
  end

  def from_map(_), do: {:error, "config must be a JSON object"}

  defp read(path) do
    case File.read(path) do
      {:ok, raw} ->
        if String.trim(raw) == "",
          do: {:error, "config #{path} is empty"},
          else: {:ok, raw}

      {:error, reason} ->
        {:error, "cannot read config #{path}: #{:file.format_error(reason)}"}
    end
  end

  defp decode(raw) do
    case JSON.decode(raw) do
      {:ok, map} when is_map(map) -> {:ok, map}
      {:ok, _} -> {:error, "config must be a JSON object"}
      {:error, reason} -> {:error, "config is not valid JSON: #{inspect(reason)}"}
    end
  end

  # Absent means the real one: an operator's config says nothing about this and should not have to.
  # With no home to find it in, the load fails closed rather than raising.
  defp grant_dir(map) do
    case Map.get(map, "grant_dir") do
      nil -> resolved_grant_dir(default_grant_dir())
      value when is_binary(value) and value != "" -> {:ok, Path.expand(value)}
      _ -> {:error, "config grant_dir must be a non-empty path"}
    end
  end

  defp resolved_grant_dir(nil), do: {:error, "cannot resolve grant_dir: HOME is not set"}
  defp resolved_grant_dir(dir), do: {:ok, dir}

  defp required_path(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) and value != "" -> {:ok, Path.expand(value)}
      _ -> {:error, "config #{key} must be a non-empty path"}
    end
  end

  # The design's §8 rule, enforced here rather than trusted: every `claude` process this
  # runner starts goes through claude-config's headless wrapper, which strips the
  # environment that silently outranks the claude.ai login. A launcher that is not that
  # script is refused, not warned about.
  defp launcher(map) do
    with {:ok, path} <- required_path(map, "claude_launcher"),
         :ok <- launcher_named(path),
         :ok <- launcher_executable(path) do
      launcher_strips_key(path)
    end
  end

  defp launcher_named(path) do
    if Path.basename(path) == @launcher_basename,
      do: :ok,
      else: {:error, "config claude_launcher must be #{@launcher_basename}, got #{path}"}
  end

  defp launcher_executable(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, mode: mode}} when Bitwise.band(mode, 0o111) != 0 -> :ok
      _ -> {:error, "config claude_launcher #{path} is not an executable file"}
    end
  end

  defp launcher_strips_key(path) do
    if File.read!(path) =~ @launcher_marker,
      do: {:ok, path},
      else: {:error, "config claude_launcher #{path} does not strip ANTHROPIC_API_KEY"}
  end

  defp repos(map) do
    case Map.get(map, "repos") do
      repos when is_map(repos) and map_size(repos) > 0 ->
        repos
        |> Enum.reduce_while({:ok, %{}}, &put_repo/2)

      _ ->
        {:error, "config repos must be a non-empty object of name => path"}
    end
  end

  defp put_repo({name, path}, {:ok, acc}) when is_binary(path) and path != "" do
    {:cont, {:ok, Map.put(acc, name, Path.expand(path))}}
  end

  defp put_repo({name, _}, _acc), do: {:halt, {:error, "config repos.#{name} must be a path"}}

  # The prefixes are DECLARED on every join (contract 1.14.0: a runner enforcing a prefix it does
  # not declare refuses every dispatch, each refusal costing the story's claim), so a list the
  # join schema would refuse must be refused HERE, at load, rather than failing every join. The
  # rules are read from the vendored contract, never re-typed.
  defp branch_prefixes(map) do
    case Map.get(map, "branch_prefixes") do
      [_ | _] = prefixes ->
        cond do
          not Enum.all?(prefixes, &(is_binary(&1) and String.length(&1) > 1)) ->
            {:error, "config branch_prefixes entries must be strings of 2+ characters"}

          (errors = declarable_errors(prefixes)) != [] ->
            {:error,
             "config branch_prefixes cannot be declared to loopctl: " <> Enum.join(errors, "; ")}

          true ->
            {:ok, prefixes}
        end

      _ ->
        {:error, "config branch_prefixes must be a non-empty list"}
    end
  end

  defp declarable_errors(prefixes) do
    schema = LoopctlRunner.Contract.schema_def("RunnerJoin")["properties"]["branch_prefixes"]

    case LoopctlRunner.Contract.validate_against(schema, prefixes, "branch_prefixes") do
      :ok -> []
      {:error, errors} -> errors
    end
  end

  # Per repo, extra environment for that repo's sessions: {"repo": {"NAME": "value"}}. In a value,
  # "{story}" becomes 8 hex of a hash of the story id, stable across that story's runs, and "{run}"
  # the first 8 hex of the run id. It is how a repo's own knobs keep a run apart from the machine's
  # shared state (home_care_billing's TEST_DB_BASE gives a story its own test database, so a
  # branch's migration never touches the checkout's). Prefer {story}: nothing drops what a value
  # creates, so {run} leaves a new database behind on every run, while {story} reuses one per
  # story, as its worktree is. A name the runner sets or reads itself (LOOP_*, LOOPCTL_*,
  # ANTHROPIC_*, GIT_*) is refused, as is one a session never inherits from the release
  # (Session.release_env_name?/1: RELEASE_*, EMU, ROOTDIR...), and a repo not in repos.
  @env_name ~r/\A[A-Z_][A-Z0-9_]{0,63}\z/
  @reserved_env ["LOOP_", "LOOPCTL_", "ANTHROPIC_", "GIT_"]

  defp session_env(map, repos) do
    case Map.get(map, "session_env", %{}) do
      env when is_map(env) ->
        Enum.reduce_while(env, {:ok, %{}}, &add_repo_env(&1, &2, repos))

      _ ->
        {:error, "config session_env must be an object"}
    end
  end

  defp add_repo_env({repo, vars}, {:ok, acc}, repos) do
    case repo_env(repo, vars, repos) do
      {:ok, vars} -> {:cont, {:ok, Map.put(acc, repo, vars)}}
      {:error, _} = error -> {:halt, error}
    end
  end

  defp repo_env(repo, vars, repos) when is_map(vars) do
    cond do
      not Map.has_key?(repos, repo) ->
        {:error, "config session_env names #{inspect(repo)}, which is not in repos"}

      bad = Enum.find(vars, fn {name, value} -> env_var_refusal(name, value) != nil end) ->
        {name, value} = bad
        {:error, "config session_env.#{repo}.#{name} #{env_var_refusal(name, value)}"}

      true ->
        {:ok, vars}
    end
  end

  defp repo_env(repo, _vars, _repos),
    do: {:error, "config session_env.#{repo} must be an object"}

  # Nil when the pair is allowed, otherwise WHY it is refused: one message for every cause sends an
  # operator who named a managed variable to look at its value, and a refused config aborts
  # rel/install.sh's whole preflight.
  defp env_var_refusal(name, value) do
    cond do
      not env_name?(name) ->
        "is not an allowed variable name"

      runner_managed_name?(name) ->
        "is a name the runner manages itself and unsets for every session, so a value here " <>
          "would be dropped silently; remove it"

      not env_value?(value) ->
        "is not a string value of at most 1024 bytes"

      true ->
        nil
    end
  end

  # PARENTHESISED ON PURPOSE. `not` binds tighter than `=~`, so `not name =~ @env_name` parses as
  # `(not name) =~ @env_name` and raises `:erlang.not("GH_TOKEN")` at runtime, on every config
  # carrying a session_env. It reads correctly in English, which is how it survives review. The
  # chain this was split out of was safe only because `not` applied to whole predicate CALLS
  # there; the moment a condition becomes an infix expression it needs its own parentheses.
  defp env_name?(name), do: is_binary(name) and name =~ @env_name

  defp runner_managed_name?(name) do
    Enum.any?(@reserved_env, &String.starts_with?(name, &1)) or
      LoopctlRunner.Session.release_env_name?(name)
  end

  defp env_value?(value),
    do: is_binary(value) and byte_size(value) <= 1024 and not String.contains?(value, <<0>>)

  @doc """
  The session environment `config` adds for `story`'s run `run_id` in `repo`, as name-value pairs.
  """
  @spec session_env_for(t(), String.t(), String.t(), String.t()) :: [{String.t(), String.t()}]
  def session_env_for(%__MODULE__{session_env: env}, repo, story_id, run_id) do
    run = binary_part(run_id, 0, 8)
    story = :sha256 |> :crypto.hash(story_id) |> Base.encode16(case: :lower) |> binary_part(0, 8)

    env
    |> Map.get(repo, %{})
    |> Enum.sort()
    |> Enum.map(fn {name, value} ->
      {name, value |> String.replace("{story}", story) |> String.replace("{run}", run)}
    end)
  end

  # Absent means this machine runs stories by hand only and never connects to loopctl.
  defp control(map) do
    case Map.fetch(map, "control") do
      :error -> {:ok, nil}
      {:ok, control} -> LoopctlRunner.ControlConfig.from_map(control)
    end
  end

  defp positive_ints(map) do
    Enum.reduce_while(@positive_ints, {:ok, []}, fn key, {:ok, acc} ->
      case Map.fetch(map, Atom.to_string(key)) do
        :error -> {:cont, {:ok, acc}}
        {:ok, value} when is_integer(value) and value > 0 -> {:cont, {:ok, [{key, value} | acc]}}
        {:ok, _} -> {:halt, {:error, "config #{key} must be a positive integer"}}
      end
    end)
  end
end
