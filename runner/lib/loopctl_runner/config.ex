defmodule LoopctlRunner.Config do
  @moduledoc """
  The runner's local configuration: machine topology and the dispatch allow-list.

  Topology never lives in source (design §13). The file is JSON, by default
  `~/.config/loopctl-runner/runner.json`, and `config/runner.example.json` documents it.

  Loading FAILS CLOSED (design §5 and §7): a missing, empty, unparseable or incomplete
  file is an error, never a default allow-list. A runner that cannot read its allow-list
  refuses every dispatch.
  """

  @default_path "~/.config/loopctl-runner/runner.json"

  @enforce_keys [:runs_dir, :claude_launcher, :claude_projects_dir, :repos, :branch_prefixes]
  defstruct [
    :runs_dir,
    :claude_launcher,
    :claude_projects_dir,
    :repos,
    :branch_prefixes,
    allowed_tools: [],
    session_env: %{},
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
          allowed_tools: [String.t()],
          session_env: %{optional(String.t()) => %{optional(String.t()) => String.t()}},
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

  @doc "Reads and validates the config file at `path`."
  @spec load(String.t()) :: {:ok, t()} | {:error, String.t()}
  def load(path) do
    with {:ok, raw} <- read(path),
         {:ok, map} <- decode(raw) do
      from_map(map)
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
         {:ok, tools} <- allowed_tools(map),
         {:ok, session_env} <- session_env(map, repos),
         {:ok, control} <- control(map),
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
           allowed_tools: tools,
           session_env: session_env,
           control: control
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

  defp branch_prefixes(map) do
    case Map.get(map, "branch_prefixes") do
      [_ | _] = prefixes ->
        if Enum.all?(prefixes, &(is_binary(&1) and String.length(&1) > 1)),
          do: {:ok, prefixes},
          else: {:error, "config branch_prefixes entries must be strings of 2+ characters"}

      _ ->
        {:error, "config branch_prefixes must be a non-empty list"}
    end
  end

  # Tool permission rules a story may request, e.g. "Bash(mix test:*)". Sessions run under
  # --permission-mode dontAsk, where these rules are the whole of what a session may do (see
  # LoopctlRunner.Session), so a rule wider than it looks is refused at load rather than trusted:
  #   - a tool the session cannot have at all (`Session.session_tools/0`) would load cleanly and
  #     be denied in every session, silently;
  #   - a file-tool rule must be scoped under the worktree, "./": a bare "Write" or
  #     "Edit(~/**)" writes anywhere this user can;
  #   - a Bash rule must name its command, and not one that runs other commands: a bare "Bash"
  #     or "Bash(bash:*)" is the first end-to-end run's commit, docker and gh over again. The
  #     list below is a backstop for a slip in the config, not the boundary; the boundary is
  #     that each rule names one command.
  # Absent means none.
  @file_tools ~w(Read Glob Grep Edit Write)
  @command_runners ~w(bash sh zsh dash fish env exec eval xargs sudo nohup timeout nice
                      python python3 perl ruby node npx elixir iex erl escript)

  defp allowed_tools(map) do
    case Map.get(map, "allowed_tools", []) do
      tools when is_list(tools) ->
        cond do
          not Enum.all?(tools, &(is_binary(&1) and &1 != "")) ->
            {:error, "config allowed_tools entries must be non-empty strings"}

          problem = Enum.find_value(tools, &rule_problem/1) ->
            {:error, "config allowed_tools " <> problem}

          true ->
            {:ok, tools}
        end

      _ ->
        {:error, "config allowed_tools must be a list"}
    end
  end

  defp rule_problem(rule) do
    {tool, spec} = rule_parts(rule)

    cond do
      tool not in LoopctlRunner.Session.session_tools() ->
        "#{inspect(rule)} names a tool sessions do not have; they have " <>
          Enum.join(LoopctlRunner.Session.session_tools(), ", ")

      tool in @file_tools and not worktree_path?(spec) ->
        "#{inspect(rule)} is not scoped to the worktree; write it as #{tool}(./<path>)"

      tool == "Bash" and not named_command?(spec) ->
        "#{inspect(rule)} does not name one command; write it as Bash(<command>:*), " <>
          "and not a shell or interpreter"

      true ->
        nil
    end
  end

  # "Bash(mix test:*)" is {"Bash", "mix test:*"}; "Read" is {"Read", nil}.
  defp rule_parts(rule) do
    case Regex.run(~r/\A([^(]+)\((.*)\)\z/s, rule) do
      [_, tool, spec] -> {tool, spec}
      nil -> {rule |> String.split("(", parts: 2) |> hd(), nil}
    end
  end

  defp worktree_path?("./" <> path),
    do: path != "" and ".." not in Path.split(path) and not String.contains?(path, "\\")

  defp worktree_path?(_spec), do: false

  defp named_command?(spec) when is_binary(spec) do
    case spec |> String.trim_leading() |> String.split([" ", ":"], parts: 2) do
      [command | _] ->
        command =~ ~r/\A[A-Za-z0-9._\/-]+\z/ and Path.basename(command) not in @command_runners

      _ ->
        false
    end
  end

  defp named_command?(_spec), do: false

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

      bad = Enum.find(vars, fn {name, value} -> not env_var?(name, value) end) ->
        {name, _} = bad
        {:error, "config session_env.#{repo}.#{name} is not an allowed variable and string value"}

      true ->
        {:ok, vars}
    end
  end

  defp repo_env(repo, _vars, _repos),
    do: {:error, "config session_env.#{repo} must be an object"}

  defp env_var?(name, value) do
    is_binary(name) and name =~ @env_name and
      not Enum.any?(@reserved_env, &String.starts_with?(name, &1)) and
      not LoopctlRunner.Session.release_env_name?(name) and
      is_binary(value) and byte_size(value) <= 1024 and not String.contains?(value, <<0>>)
  end

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
