defmodule LoopctlRunner.DispatchRun do
  @moduledoc """
  What an accepted dispatch becomes on this machine, and what its run reports back: the story
  object read from the dispatch, the `LoopctlRunner.Story` a `LoopctlRunner.Run` executes, the
  run's binding, and its `stage` reports. Pure functions; `LoopctlRunner.Control` performs them.

  ## The story object

  Contract 1.5.0 (loopctl PR #829) adds a `RunnerDispatch.story` object carrying the story's
  typed fields, sent only on an `implement` dispatch. The vendored 1.4.0 schema does not know it,
  so it is read defensively here, against 1.5.0's per-field caps, counted in characters
  (`String.length/1`, as the vendored validator counts `maxLength`):

    * `id` (required) — a UUID equal to the dispatch's `story_id`, compared lowercased;
    * `title` (required) — 1 to 200; `description` — up to 8000; `domain_reference` — 1 to 500;
    * `acceptance_criteria` and `test_cases` — at most 20 items of 1 to 500;
    * `touches` — at most 100 items of 1 to 200.

  The whole-object cap of 48 000 bytes is loopctl's to check. A value of the wrong type or outside
  its bounds refuses the dispatch whole; nothing is truncated, so a hostile value padded past a
  cap cannot have its tail trimmed into a clean-looking one.
  """

  alias LoopctlRunner.{Config, Contract, DispatchPrompt, Story}

  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i

  # key => {min, max} characters
  @text_bounds %{"title" => {1, 200}, "description" => {0, 8000}, "domain_reference" => {1, 500}}
  # key => {max items, {min, max} characters per item}
  @list_bounds %{
    "acceptance_criteria" => {20, {1, 500}},
    "test_cases" => {20, {1, 500}},
    "touches" => {100, {1, 200}}
  }

  @max_reason Map.fetch!(Map.fetch!(Contract.connection(), "limits"), "stage_max_reason_length")

  @finished_reason "first end-to-end run: implementation finished, merging nothing by design"

  @doc "The escalation reason of a run that finished its implementation."
  @spec finished_reason() :: String.t()
  def finished_reason, do: @finished_reason

  @doc """
  The dispatch's story object: `{:ok, story}` with only the known keys, `:none` when the
  dispatch carries none, or `{:error, detail}` when it is malformed.
  """
  @spec story_object(map()) :: {:ok, map()} | :none | {:error, String.t()}
  def story_object(dispatch) do
    case Map.fetch(dispatch, "story") do
      :error -> :none
      {:ok, nil} -> :none
      {:ok, story} when is_map(story) -> validate_story(story, dispatch["story_id"])
      {:ok, _} -> {:error, "the dispatch story is not an object"}
    end
  end

  defp validate_story(story, story_id) do
    with :ok <- check_story_id(story["id"], story_id),
         :ok <- required_title(story),
         :ok <- texts(story),
         :ok <- lists(story) do
      {:ok, Map.take(story, ["id" | Map.keys(@text_bounds) ++ Map.keys(@list_bounds)])}
    end
  end

  defp check_story_id(id, dispatch_story_id) when is_binary(id) do
    cond do
      not Regex.match?(@uuid, id) ->
        {:error, "the dispatch story id is not a uuid"}

      not is_binary(dispatch_story_id) or
          String.downcase(id) != String.downcase(dispatch_story_id) ->
        {:error, "the dispatch story id is not the dispatch's story_id"}

      true ->
        :ok
    end
  end

  defp check_story_id(nil, _dispatch_story_id), do: {:error, "the dispatch story has no id"}

  defp check_story_id(_id, _dispatch_story_id),
    do: {:error, "the dispatch story id is not a uuid"}

  defp required_title(%{"title" => title}) when title != nil, do: :ok
  defp required_title(_story), do: {:error, "the dispatch story has no title"}

  defp texts(story) do
    Enum.find_value(@text_bounds, :ok, fn {key, bounds} ->
      case text(story[key], bounds) do
        :ok -> nil
        {:error, what} -> {:error, "the dispatch story #{key} #{what}"}
      end
    end)
  end

  defp lists(story) do
    Enum.find_value(@list_bounds, :ok, fn {key, {max_items, bounds}} ->
      case story[key] do
        nil ->
          nil

        items when is_list(items) and length(items) <= max_items ->
          list_items(key, items, bounds)

        items when is_list(items) ->
          {:error, "the dispatch story #{key} has more than #{max_items} items"}

        _ ->
          {:error, "the dispatch story #{key} is not a list"}
      end
    end)
  end

  # The first item out of bounds, or nil when every item is in them.
  defp list_items(key, items, bounds) do
    items
    |> Enum.with_index()
    |> Enum.find_value(fn {item, i} ->
      case item_text(item, bounds) do
        :ok -> nil
        {:error, what} -> {:error, "the dispatch story #{key}[#{i}] #{what}"}
      end
    end)
  end

  # A list item is a string within its bounds, never null: null stands only for an absent
  # optional top-level field, and a null item would reach the prompt builder as nil.
  defp item_text(nil, _bounds), do: {:error, "is null"}
  defp item_text(item, bounds), do: text(item, bounds)

  defp text(nil, _bounds), do: :ok

  defp text(value, {min, max}) when is_binary(value) do
    cond do
      not String.valid?(value) -> {:error, "is not valid UTF-8"}
      String.length(value) < min -> {:error, "is shorter than #{min} characters"}
      String.length(value) > max -> {:error, "is longer than #{max} characters"}
      true -> :ok
    end
  end

  defp text(_value, _bounds), do: {:error, "is not a string"}

  @doc """
  The `Story` an accepted dispatch runs: the policy's fields, a local id derived from the
  dispatch, the prompt from `LoopctlRunner.DispatchPrompt`, and the runner config's own
  `allowed_tools`, never the dispatch's.
  """
  @spec story(map(), map(), map(), Config.t()) :: {:ok, Story.t()} | {:error, String.t()}
  def story(dispatch, fields, story_object, %Config{} = config) do
    Story.from_map(
      %{
        "id" => story_id(dispatch["story_id"]),
        "repo" => fields.repo,
        "base" => fields.base,
        "branch" => fields.branch,
        "prompt" =>
          DispatchPrompt.build(story_object, %{
            repo: dispatch["repo"],
            branch: fields.branch,
            base: fields.base
          }),
        "wall_clock_s" => fields.wall_clock_s,
        "max_turns" => fields.max_turns,
        "allowed_tools" => config.allowed_tools
      },
      config
    )
  end

  @doc """
  The local story id, and so the worktree path, for a dispatch's `story_id`: `story-` and the
  lowercased UUID (42 characters). Keyed on the story, not the dispatch, so a later dispatch of
  the same story (after a reclaim, or re-queued after `escalated`) finds the worktree the earlier
  run kept and adopts it, instead of refusing a branch that exists without a worktree.
  """
  @spec story_id(String.t()) :: String.t()
  def story_id(story_id), do: "story-" <> String.downcase(story_id)

  @doc "What an accepted run's `state.json` carries so its trace ships: the dispatch it serves."
  @spec binding(map()) :: map()
  def binding(dispatch) do
    %{
      "dispatch_id" => dispatch["dispatch_id"],
      "claim_epoch" => dispatch["claim_epoch"],
      "story_id" => dispatch["story_id"]
    }
  end

  @doc """
  A `RunnerStageReport` for the dispatch, validated against the contract. `opts` may carry
  `:edge`, `:reason` (capped at the contract's reason length, in codepoints) and `:effects`.
  """
  @spec stage_report(map(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, [String.t()]}
  def stage_report(dispatch, from, to, opts \\ []) do
    payload =
      %{
        "dispatch_id" => dispatch["dispatch_id"],
        "claim_epoch" => dispatch["claim_epoch"],
        "from" => from,
        "to" => to
      }
      |> put_opt("edge", opts[:edge])
      |> put_opt("reason", opts[:reason] && cap_reason(opts[:reason]))
      |> put_opt("effects", opts[:effects])

    with :ok <- Contract.validate("RunnerStageReport", payload), do: {:ok, payload}
  end

  defp put_opt(payload, _key, nil), do: payload
  defp put_opt(payload, key, value), do: Map.put(payload, key, value)

  @doc """
  A reason cut to the contract's `stage_max_reason_length` counted in CODEPOINTS: the schema's
  `maxLength` counts graphemes, which is looser, and loopctl refuses by codepoints.
  """
  @spec cap_reason(String.t()) :: String.t()
  def cap_reason(reason) do
    reason |> String.codepoints() |> Enum.take(@max_reason) |> Enum.join()
  end

  @doc """
  The reason a run's stage stream ends `escalated` with: exactly `finished_reason/0` for a run
  that finished its implementation, and otherwise the run's outcome — its status, why the
  session ended, and what the session escalated with if it called loop-escalate.
  """
  @spec end_reason(map()) :: String.t()
  def end_reason(%{status: "succeeded"}), do: @finished_reason

  def end_reason(summary) do
    parts =
      [
        "run ended #{summary[:status] || "crashed"}",
        summary[:exit_reason] && "session exit reason #{summary[:exit_reason]}",
        summary[:exit_status] && "exit status #{summary[:exit_status]}",
        summary[:error] && "error: #{summary[:error]}",
        escalations(summary[:escalations])
      ]
      |> Enum.reject(&(&1 in [nil, ""]))

    parts |> Enum.join("; ") |> cap_reason()
  end

  defp escalations(list) when is_list(list) and list != [],
    do: "the session escalated: " <> Enum.join(list, " | ")

  defp escalations(_list), do: nil
end
