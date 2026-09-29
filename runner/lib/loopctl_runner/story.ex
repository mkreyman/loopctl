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
    :deadline_at
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          repo: String.t(),
          repo_path: String.t(),
          base: String.t(),
          branch: String.t(),
          prompt: String.t() | nil,
          wall_clock_s: pos_integer(),
          max_turns: pos_integer(),
          model: String.t() | nil,
          deadline_at: DateTime.t() | nil
        }

  @id_format ~r/\A[a-z0-9][a-z0-9._-]{0,62}\z/
  @ref_format ~r/\A[A-Za-z0-9][A-Za-z0-9._\/-]{0,199}\z/

  @spec load(String.t(), Config.t()) :: {:ok, t()} | {:error, String.t()}
  def load(path, %Config{} = config) do
    with {:ok, raw} <- File.read(path) |> file_error(path), do: from_json(raw, config)
  end

  @doc "The story the JSON text `raw` describes, validated against `config`."
  @spec from_json(String.t(), Config.t()) :: {:ok, t()} | {:error, String.t()}
  def from_json(raw, %Config{} = config) do
    with {:ok, map} <- decode(raw), do: from_map(map, config)
  end

  @doc """
  The story `map` describes, validated against `config`. With `prompt: :deferred` the map carries
  no prompt and the story's is nil: a dispatch's prompt can only be built once its run has cut the
  worktree (`LoopctlRunner.Run.execute/3`'s `:prompt`), and a placeholder here would be a prompt
  nobody meant.
  """
  @spec from_map(map(), Config.t(), keyword()) :: {:ok, t()} | {:error, String.t()}
  def from_map(map, config, opts \\ [])

  def from_map(map, %Config{} = config, opts) when is_map(map) do
    with {:ok, id} <- matching(map, "id", @id_format),
         {:ok, repo, repo_path} <- repo(map, config),
         {:ok, base} <- matching(map, "base", @ref_format),
         {:ok, branch} <- branch(map, config),
         {:ok, prompt} <- prompt(map, Keyword.get(opts, :prompt)),
         {:ok, wall_clock_s} <- bounded(map, "wall_clock_s", config.max_wall_clock_s),
         {:ok, max_turns} <- bounded(map, "max_turns", config.max_turns),
         {:ok, model} <- model(map),
         {:ok, deadline_at} <- parse_deadline(Map.get(map, "deadline_at")) do
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
         deadline_at: deadline_at
       }}
    end
  end

  def from_map(_, _, _), do: {:error, "story must be a JSON object"}

  @doc "The story as JSON-encodable data, for the run directory."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = story), do: Map.from_struct(story)

  @doc """
  A story's `deadline_at`: nil when absent, else the instant. A dispatch's arrives already an
  instant (`deadline!/1`, in `LoopctlRunner.DispatchPolicy.decide/3`) and is kept as it is; a
  hand-filed story's is a string nothing validated, so a malformed one is an error here.
  """
  @spec parse_deadline(term()) :: {:ok, DateTime.t() | nil} | {:error, String.t()}
  def parse_deadline(nil), do: {:ok, nil}
  def parse_deadline(%DateTime{} = deadline), do: {:ok, deadline}

  def parse_deadline(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, deadline, _offset} -> {:ok, deadline}
      {:error, _} -> {:error, "story deadline_at is not an ISO-8601 date-time"}
    end
  end

  def parse_deadline(_value), do: {:error, "story deadline_at is not an ISO-8601 date-time"}

  @doc """
  A DISPATCH's `deadline_at` as an instant, nil when absent: the one place it is parsed, and the
  instant is what travels from there (`LoopctlRunner.DispatchPolicy.decide/3`'s fields). The
  contract's `date-time` format was already enforced by `LoopctlRunner.Contract`, which accepts
  exactly what `DateTime.from_iso8601/1` does, so a value that does not parse cannot reach here;
  if one did, this raises, and the accept path's guard refuses the dispatch.
  """
  @spec deadline!(String.t() | nil) :: DateTime.t() | nil
  def deadline!(nil), do: nil

  def deadline!(value) when is_binary(value) do
    {:ok, deadline, _offset} = DateTime.from_iso8601(value)
    deadline
  end

  # CLOCK SKEW between this machine and loopctl's, which the runner cannot measure: nothing on the
  # wire carries loopctl's clock, and `deadline_at` is an instant on THAT clock. The stop is aimed
  # this far ahead of what the kill grace alone needs, so a clock up to this far behind loopctl's
  # still has the session gone by the deadline. A clock further behind than this is the operator's
  # to fix (NTP); a margin is all the runner can do about it.
  @deadline_margin_s 5

  @doc "The clock-skew margin the stop is aimed ahead of `deadline_at` by, in seconds."
  @spec deadline_margin_s() :: pos_integer()
  def deadline_margin_s, do: @deadline_margin_s

  @doc """
  The instant a session bound by `deadline` must be SIGNALLED to stop for it to be gone by then:
  `deadline_at` less the kill grace (TERM, then up to `kill_grace_s` before KILL) and the skew
  margin. nil when there is no deadline.
  """
  @spec stop_by(DateTime.t() | nil, non_neg_integer(), non_neg_integer()) :: DateTime.t() | nil
  def stop_by(nil, _kill_grace_s, _margin_s), do: nil

  def stop_by(%DateTime{} = deadline, kill_grace_s, margin_s),
    do: DateTime.add(deadline, -(kill_grace_s + margin_s), :second)

  @doc """
  When to stop a session that starts at `started_at`, in milliseconds after it, and which bound that
  is: the EARLIER of its own start + `wall_clock_s` (`:wall_clock`) and `stop_by/3` of its
  `deadline_at` (`:deadline`) — contract 1.19.0, `RunnerDispatch.deadline_at`: "end the session by
  the EARLIER of your own start + `wall_clock_seconds` and this instant". Taken when the session
  starts, so the time between the accept and the start comes out of the deadline's grace. Never
  negative; a tie is the wall clock's.
  """
  @spec stop_after(t(), DateTime.t(), non_neg_integer(), non_neg_integer()) ::
          {non_neg_integer(), :wall_clock | :deadline}
  def stop_after(
        %__MODULE__{wall_clock_s: wall_clock_s} = story,
        started_at,
        kill_grace_s,
        margin_s
      ) do
    wall_clock_ms = wall_clock_s * 1000

    case stop_by(story.deadline_at, kill_grace_s, margin_s) do
      nil ->
        {wall_clock_ms, :wall_clock}

      stop_by ->
        deadline_ms = max(DateTime.diff(stop_by, started_at, :millisecond), 0)

        if deadline_ms < wall_clock_ms,
          do: {deadline_ms, :deadline},
          else: {wall_clock_ms, :wall_clock}
    end
  end

  @doc """
  THE deadline guard: whether work bound by `deadline` may still begin at `now`, for a session whose
  own budget is `wall_clock_s`. It may only when `stop_by/3` — `deadline_at` less
  `config.kill_grace_s` and `deadline_margin_s/0` — is at least the MINIMUM RUNTIME after `now`:
  the lesser of `config.min_session_s` and `wall_clock_s`. Otherwise `{:passed, detail}`. A session
  started with less would be stopped almost as it started, so none is started. The floor is capped
  by the session's own budget because a dispatch asking for less than `min_session_s` of session is
  asking for exactly that much, and measuring it against more would refuse it however early it
  came. No deadline never passes.

  Every check is this one: the accept (`LoopctlRunner.DispatchPolicy.decide/3`, which a pending
  start restored after a restart goes through too), the start of a run, and the moment before its
  session starts (`LoopctlRunner.Run`, `LoopctlRunner.TriageRun`).
  """
  @spec check_deadline(DateTime.t() | nil, pos_integer(), Config.t(), DateTime.t()) ::
          :ok | {:passed, String.t()}
  def check_deadline(nil, _wall_clock_s, %Config{}, _now), do: :ok

  def check_deadline(%DateTime{} = deadline, wall_clock_s, %Config{} = config, now) do
    stop_by = stop_by(deadline, config.kill_grace_s, @deadline_margin_s)
    floor_s = min(config.min_session_s, wall_clock_s)

    if DateTime.diff(stop_by, now, :millisecond) >= floor_s * 1000 do
      :ok
    else
      {:passed,
       "deadline_passed: the dispatch's deadline_at #{DateTime.to_iso8601(deadline)} leaves " <>
         "less than #{floor_s}s of session before it must be stopped " <>
         "(#{config.kill_grace_s}s kill grace + #{@deadline_margin_s}s clock-skew margin; " <>
         "now #{DateTime.to_iso8601(now)})"}
    end
  end

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

  defp prompt(_map, :deferred), do: {:ok, nil}

  defp prompt(map, nil) do
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

  defp model(map) do
    case Map.get(map, "model") do
      nil -> {:ok, nil}
      model when is_binary(model) -> matching(map, "model", ~r/\A[a-z0-9][a-z0-9.\[\]-]{0,63}\z/)
      _ -> {:error, "story model must be a string"}
    end
  end
end
