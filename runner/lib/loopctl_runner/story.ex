defmodule LoopctlRunner.Story do
  @moduledoc """
  A hand-filed story (build order step 1a) validated against the local allow-list.

  The runner refuses by default (design §7): a story naming a repo that is not
  configured, a branch outside the allowed prefixes, or a budget above the configured
  ceiling is rejected before anything touches the filesystem.
  """

  alias LoopctlRunner.Config

  @enforce_keys [:id, :repo, :repo_path, :base, :branch, :prompt, :wall_clock_s, :max_turns]
  defstruct [
    :id,
    :repo,
    :repo_path,
    :base,
    :branch,
    :prompt,
    :wall_clock_s,
    :max_turns,
    :model,
    allowed_tools: []
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          repo: String.t(),
          repo_path: String.t(),
          base: String.t(),
          branch: String.t(),
          prompt: String.t(),
          wall_clock_s: pos_integer(),
          max_turns: pos_integer(),
          model: String.t() | nil,
          allowed_tools: [String.t()]
        }

  @id_format ~r/\A[a-z0-9][a-z0-9._-]{0,62}\z/
  @ref_format ~r/\A[A-Za-z0-9][A-Za-z0-9._\/-]{0,199}\z/

  @spec load(String.t(), Config.t()) :: {:ok, t()} | {:error, String.t()}
  def load(path, %Config{} = config) do
    with {:ok, raw} <- File.read(path) |> file_error(path),
         {:ok, map} <- decode(raw) do
      from_map(map, config)
    end
  end

  @spec from_map(map(), Config.t()) :: {:ok, t()} | {:error, String.t()}
  def from_map(map, %Config{} = config) when is_map(map) do
    with {:ok, id} <- matching(map, "id", @id_format),
         {:ok, repo, repo_path} <- repo(map, config),
         {:ok, base} <- matching(map, "base", @ref_format),
         {:ok, branch} <- branch(map, config),
         {:ok, prompt} <- prompt(map),
         {:ok, wall_clock_s} <- bounded(map, "wall_clock_s", config.max_wall_clock_s),
         {:ok, max_turns} <- bounded(map, "max_turns", config.max_turns),
         {:ok, model} <- model(map),
         {:ok, tools} <- allowed_tools(map, config) do
      {:ok,
       %__MODULE__{
         id: id,
         repo: repo,
         repo_path: repo_path,
         base: base,
         branch: branch,
         prompt: prompt,
         wall_clock_s: wall_clock_s,
         max_turns: max_turns,
         model: model,
         allowed_tools: tools
       }}
    end
  end

  def from_map(_, _), do: {:error, "story must be a JSON object"}

  @doc "The story as JSON-encodable data, for the run directory."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = story), do: Map.from_struct(story)

  defp file_error({:ok, raw}, _path), do: {:ok, raw}

  defp file_error({:error, reason}, path),
    do: {:error, "cannot read story #{path}: #{:file.format_error(reason)}"}

  defp decode(raw) do
    case JSON.decode(raw) do
      {:ok, map} when is_map(map) -> {:ok, map}
      {:ok, _} -> {:error, "story must be a JSON object"}
      {:error, reason} -> {:error, "story is not valid JSON: #{inspect(reason)}"}
    end
  end

  defp matching(map, key, format) do
    value = Map.get(map, key)

    if is_binary(value) and value =~ format and not String.contains?(value, ".."),
      do: {:ok, value},
      else: {:error, "story #{key} is missing or malformed"}
  end

  defp repo(map, config) do
    name = Map.get(map, "repo")

    case is_binary(name) && Map.fetch(config.repos, name) do
      {:ok, path} -> {:ok, name, path}
      _ -> {:error, "story repo #{inspect(name)} is not in the runner allow-list"}
    end
  end

  defp branch(map, config) do
    with {:ok, branch} <- matching(map, "branch", @ref_format) do
      if Enum.any?(config.branch_prefixes, &String.starts_with?(branch, &1)),
        do: {:ok, branch},
        else: {:error, "story branch #{branch} is outside the allowed prefixes"}
    end
  end

  defp prompt(map) do
    case Map.get(map, "prompt") do
      prompt when is_binary(prompt) ->
        if String.trim(prompt) == "",
          do: {:error, "story prompt must be non-empty"},
          else: {:ok, prompt}

      _ ->
        {:error, "story prompt must be non-empty"}
    end
  end

  defp bounded(map, key, ceiling) do
    case Map.get(map, key) do
      value when is_integer(value) and value > 0 and value <= ceiling ->
        {:ok, value}

      value when is_integer(value) and value > ceiling ->
        {:error, "story #{key} #{value} exceeds the runner ceiling #{ceiling}"}

      _ ->
        {:error, "story #{key} must be a positive integer"}
    end
  end

  defp allowed_tools(map, config) do
    case Map.get(map, "allowed_tools", []) do
      tools when is_list(tools) ->
        case Enum.reject(tools, &(&1 in config.allowed_tools)) do
          [] ->
            {:ok, tools}

          refused ->
            {:error, "story allowed_tools #{inspect(refused)} are not in the runner allow-list"}
        end

      _ ->
        {:error, "story allowed_tools must be a list"}
    end
  end

  defp model(map) do
    case Map.get(map, "model") do
      nil -> {:ok, nil}
      model when is_binary(model) -> matching(map, "model", ~r/\A[a-z0-9][a-z0-9.\[\]-]{0,63}\z/)
      _ -> {:error, "story model must be a string"}
    end
  end
end
