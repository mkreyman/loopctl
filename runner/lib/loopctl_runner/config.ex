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
    max_wall_clock_s: 3600,
    max_turns: 200,
    park_after_s: 600,
    liveness_interval_s: 30,
    kill_grace_s: 10,
    agents_probe_timeout_s: 20
  ]

  @type t :: %__MODULE__{
          runs_dir: String.t(),
          claude_launcher: String.t(),
          claude_projects_dir: String.t(),
          repos: %{optional(String.t()) => String.t()},
          branch_prefixes: [String.t()],
          allowed_tools: [String.t()],
          max_wall_clock_s: pos_integer(),
          max_turns: pos_integer(),
          park_after_s: pos_integer(),
          liveness_interval_s: pos_integer(),
          kill_grace_s: pos_integer(),
          agents_probe_timeout_s: pos_integer()
        }

  @positive_ints [
    :max_wall_clock_s,
    :max_turns,
    :park_after_s,
    :liveness_interval_s,
    :kill_grace_s,
    :agents_probe_timeout_s
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
           allowed_tools: tools
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

  # Tool permission rules a story may request, e.g. "Bash(mix test:*)". Unattended sessions
  # run with --permission-prompts none, which DENIES every call auto mode would have
  # prompted for (measured: a repo script under the Bash tool), so a session can only run
  # what is pre-allowed. Absent means none.
  defp allowed_tools(map) do
    case Map.get(map, "allowed_tools", []) do
      tools when is_list(tools) ->
        if Enum.all?(tools, &(is_binary(&1) and &1 != "")),
          do: {:ok, tools},
          else: {:error, "config allowed_tools entries must be non-empty strings"}

      _ ->
        {:error, "config allowed_tools must be a list"}
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
