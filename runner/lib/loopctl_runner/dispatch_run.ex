defmodule LoopctlRunner.DispatchRun do
  @moduledoc """
  What an accepted dispatch becomes on this machine, and what its run reports back: the story
  object read from the dispatch, the `LoopctlRunner.Story` a `LoopctlRunner.Run` executes, the
  run's binding, and its `stage` reports. Pure functions; `LoopctlRunner.Control` performs them.

  ## The story object

  Contract 1.5.0 (loopctl PR #829) adds a `RunnerDispatch.story` object carrying the story's
  typed fields, sent only on an `implement` dispatch. The contract's own validation checks it
  first; it is read again here as the second line, with the bounds taken from the vendored
  contract at compile time (`limits.story.fields` and `$defs.RunnerStory`, never re-typed),
  counted in characters (`String.length/1`, as the vendored validator counts `maxLength`), and
  for what the schema cannot say:

    * `id` (required) — a UUID equal to the dispatch's `story_id`, compared lowercased;
    * `title` (required) — 1 to 200; `description` — up to 8000; `domain_reference` — 1 to 500;
    * `acceptance_criteria` and `test_cases` — at most 20 items of 1 to 500;
    * `touches` — at most 100 items of 1 to 200.

  The whole-object cap of 48 000 bytes is loopctl's to check. A value of the wrong type or outside
  its bounds refuses the dispatch whole; nothing is truncated, so a hostile value padded past a
  cap cannot have its tail trimmed into a clean-looking one.
  """

  require Logger

  alias LoopctlRunner.{
    Config,
    Contract,
    DispatchPolicy,
    PrStages,
    Run,
    Story,
    Templates,
    Uuid,
    Worktree
  }

  # The bounds come from the vendored contract, never re-typed: maxima from the published
  # x-connection.limits.story.fields (derived on loopctl's side from the schema), minima from
  # $defs.RunnerStory. A story field the schema adds lands here on the next vendoring.
  @story_schema Contract.schema_def("RunnerStory")
  @story_limits get_in(Contract.connection(), ["limits", "story", "fields"])

  # key => {min, max} characters
  @text_bounds (for {key, %{"max_length" => max}} <- @story_limits, into: %{} do
                  {key, {get_in(@story_schema, ["properties", key, "minLength"]) || 0, max}}
                end)

  # key => {max items, {min, max} characters per item}
  @list_bounds (for {key, %{"max_items" => items, "max_item_length" => max}} <- @story_limits,
                    into: %{} do
                  min = get_in(@story_schema, ["properties", key, "items", "minLength"]) || 0
                  {key, {items, {min, max}}}
                end)

  @max_reason Map.fetch!(Map.fetch!(Contract.connection(), "limits"), "stage_max_reason_length")

  # What a `session_ended` refusal means, read from the contract rather than listed here: the
  # reasons it publishes for the event, and which of them `permanent_errors` says never clear —
  # for every event (`*`) and for this one. `dispatch_not_accepted` also carries a CONDITION
  # (permanent unless an accept this runner sent is still unacknowledged), which cannot hold here:
  # a run starts only once loopctl has acknowledged its accept, so by the time its session has
  # ended there is no accept outstanding, and the reason is as permanent as `*` says.
  @session_ended_errors Map.fetch!(Map.fetch!(Contract.connection(), "errors"), "session_ended")
  @session_ended_permanent Contract.permanent_errors("session_ended")

  # Every refusal the contract publishes for the event is handled by name or known permanent. A
  # vendoring that adds a transient one fails the build here, where deciding is cheap, instead of
  # being given up at runtime as unknown.
  unhandled =
    @session_ended_errors -- (~w(rate_limited internal_error) ++ @session_ended_permanent)

  if unhandled != [] do
    raise "the vendored contract publishes #{Enum.join(unhandled, ", ")} for a session_ended, " <>
            "which DispatchRun neither handles by name nor knows to be permanent"
  end

  @session_ended_reasons Contract.schema_def("RunnerSessionEnded")
                         |> get_in(["properties", "reason", "enum"])

  for reason <- ~w(completed wall_clock_exceeded max_turns_exceeded crashed) do
    unless reason in @session_ended_reasons do
      raise "DispatchRun reports session_ended #{reason}, which the vendored contract does not publish"
    end
  end

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
      not Uuid.valid?(id) ->
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
  The `Story` an accepted dispatch runs: the policy's fields — its `deadline_at` among them, the
  instant `DispatchPolicy.decide/3` parsed — and a local id derived from the dispatch. Its prompt is
  deferred (`Story.from_map/3`): `LoopctlRunner.Run.execute/3` builds it with `prompt/4`'s function
  once the worktree exists, and nothing builds one before that.
  """
  @spec story(map(), map(), Config.t()) :: {:ok, Story.t()} | {:error, String.t()}
  def story(dispatch, fields, %Config{} = config) do
    Story.from_map(
      %{
        "id" => story_id(dispatch["story_id"]),
        "repo" => fields.repo,
        "base" => fields.base,
        "branch" => fields.branch,
        "wall_clock_s" => fields.wall_clock_s,
        "max_turns" => fields.max_turns,
        # Contract 1.19.0's stop bound, nil on a dispatch not placed under a claim. Kept an INSTANT
        # and turned into a timer only when the session starts (`Story.stop_after/4`), so start-up
        # time comes out of the grace.
        "deadline_at" => fields.deadline_at
      },
      config,
      prompt: :deferred
    )
  end

  # `.loopctl/mode` holds one word; anything much longer is not a mode, and is refused unread.
  @max_mode_bytes 64

  @doc """
  What `Run.execute/3` calls, through `:prompt`, once the worktree is cut, with the commit it was
  cut from (`Worktree.create/4`'s `cut_from`): the session's prompt, or the refusal that stops the
  run before a session starts.

  The delivery mode is `.loopctl/mode` as THAT commit holds it (`Worktree.commit_file/4`) — the
  tree the session starts in, and written by no session — normalised and checked by
  `DispatchPolicy.delivery_mode/1`. A refusal fails the dispatch closed.

  The prompt is `template`'s (`LoopctlRunner.Templates.render/2`); implement@1 when none is given.
  """
  @spec prompt(map(), map(), map(), Templates.t() | nil) ::
          (String.t() -> {:ok, String.t()} | {:refuse, String.t(), String.t()})
  def prompt(dispatch, fields, story_object, template \\ nil) do
    template = template || implement_template()

    where = %{
      repo: dispatch["repo"],
      branch: fields.branch,
      base: fields.base,
      # Contract 1.31.0: the verifier rejected this story's open pull request, and the session
      # continues it rather than starting over. Already validated with the rest of the dispatch.
      rework: dispatch["rework"]
    }

    fn cut_from ->
      read = Worktree.commit_file(fields.repo_path, cut_from, ".loopctl/mode", @max_mode_bytes)

      with {:ok, mode} <- DispatchPolicy.delivery_mode(read) do
        {:ok,
         Templates.render(template, %{story: story_object, where: Map.put(where, :mode, mode)})}
      end
    end
  end

  # How long the forge is given to answer (`LoopctlRunner.Forge`'s own kill), and how much longer
  # `observe/4` waits for the call around it before giving it up: a seam that ignores its timeout
  # must not hold the run's end, and with it `session_ended`.
  @forge_timeout_ms 30_000
  @forge_grace_ms 2_000

  @doc """
  What `Run.execute/3` calls, through `:observe`, once a dispatch's session has ended, however it
  ended (US-48.16): the forward stages its pull request shows, for the run to report before its
  `session_ended`, or `[]`.

  Only a `pr`-mode session gets any, read as `prompt/4` reads it: `.loopctl/mode` in the commit the
  worktree was cut from, never the working tree the session could write. In `pr` mode the session
  opens its pull request with `gh pr create --base <base>` (on a rework dispatch, contract
  1.31.0, it pushes to the pull request the dispatch names instead) and stops at green CI; it
  never merges (US-48.17). loopctl merges it later, through a `merge` instruction
  (`LoopctlRunner.MergeRun`), once an independent verifier passed the head and the merge gate
  allowed it. Nothing the session says tells loopctl how far its pull request got, so the runner
  asks the forge about the dispatch's own repo, branch and base and nothing else, and
  `LoopctlRunner.PrStages` says what that answer shows.
  Every value reported is the forge's; none comes from session text or a file the session wrote.

  `forge` is `(repo, head, base, timeout_ms) -> {:ok, list} | {:error, reason}` —
  `LoopctlRunner.Forge.pull_requests/5` in production. Bounded: `:timeout_ms` (30 s) is what the
  forge is given, and the call is given up `:grace_ms` (2 s) after that. A forge that fails, times
  out, raises or answers anything else reports nothing extra and logs a warning; the run's end, its
  `session_ended` included, goes out either way.
  """
  @spec observe(map(), Story.t(), function(), keyword()) :: (map() -> [map()])
  def observe(dispatch, %Story{} = story, forge, opts \\ []) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @forge_timeout_ms)
    bound_ms = timeout_ms + Keyword.get(opts, :grace_ms, @forge_grace_ms)
    where = {dispatch["repo"], story.branch, story.base}

    fn context ->
      with cut_from when is_binary(cut_from) <- context[:cut_from],
           read =
             Worktree.commit_file(story.repo_path, cut_from, ".loopctl/mode", @max_mode_bytes),
           {:ok, "pr"} <- DispatchPolicy.delivery_mode(read) do
        ask_forge(forge, where, timeout_ms, bound_ms, dispatch)
      else
        _not_pr -> []
      end
    end
  end

  defp ask_forge(forge, {repo, head, base} = where, timeout_ms, bound_ms, dispatch) do
    task =
      Task.async(fn ->
        try do
          forge.(repo, head, base, timeout_ms)
        catch
          kind, reason -> {:error, Run.crash_error(kind, reason)}
        end
      end)

    answer =
      case Task.yield(task, bound_ms) || Task.shutdown(task, :brutal_kill) do
        {:ok, answer} -> answer
        _ -> {:error, "the forge did not answer within #{bound_ms} ms"}
      end

    case answer do
      {:ok, prs} ->
        PrStages.observed(prs, head, base)

      other ->
        forge_failed(where, other, dispatch)
    end
  end

  defp forge_failed({repo, head, base}, answer, dispatch) do
    why =
      case answer do
        {:error, reason} when is_binary(reason) -> reason
        other -> "an answer that is not {:ok, list}: #{inspect(other, limit: 5)}"
      end

    Logger.warning(
      "could not read the forge for #{repo} #{head} into #{base} (#{why}); no stage past " <>
        "implementing is reported for this session, and its session_ended still goes",
      dispatch_id: dispatch["dispatch_id"]
    )

    []
  end

  # implement@1, the template a caller that names none gets: today's prompt.
  defp implement_template do
    {:ok, template} = Templates.fetch({"implement", 1})
    template
  end

  @doc """
  The local story id, and so the worktree path, for a dispatch's `story_id`: `story-` and the
  lowercased UUID (42 characters). Keyed on the story, not the dispatch, so a later dispatch of
  the same story (after a reclaim, or re-queued after `escalated`) finds the worktree the earlier
  run kept and adopts it, instead of refusing a branch that exists without a worktree.
  """
  @spec story_id(String.t()) :: String.t()
  def story_id(story_id), do: "story-" <> String.downcase(story_id)

  @doc """
  What an accepted run's `state.json` carries so its trace ships: the dispatch it serves. A
  story-less dispatch (`spec_tune`, contract 1.30.0) has no `story_id`, and its binding carries
  none rather than a null one.
  """
  @spec binding(map()) :: map()
  def binding(dispatch) do
    binding = %{
      "dispatch_id" => dispatch["dispatch_id"],
      "claim_epoch" => dispatch["claim_epoch"]
    }

    case dispatch["story_id"] do
      story_id when is_binary(story_id) -> Map.put(binding, "story_id", story_id)
      _none -> binding
    end
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
  def cap_reason(reason), do: Contract.fit(reason, @max_reason)

  @doc """
  What a run's end is reported as, in the order it goes out, from the run's summary (or the
  `status`, `reached` and escalations a later Control reads back from `state.json`):

    * `[]` — an implement run's `deadline_at` passed before its session started (status
      `deadline_passed`, from `claimed`, `worktree` or `implementing`): it started no session,
      and escalating the story would say a human is needed when none is. After its deadline the claim is loopctl's lease sweep's, which releases it; the run
      records its end as settled (`terminal_reported` `skipped`), so no Control reports it later.
    * `[:escalated]` — no session ever started: the run got no worktree (`reached` `claimed`), or
      its prompt was refused (`worktree`). There is no session to say `session_ended` about, so
      the `-> escalated` stage report is the whole of its end.
    * `[:escalated, :session_ended]` — the session ran `loop-escalate`: the story is escalated,
      which is what the session asked for, and then its session is reported ended (see
      `session_ended/2` for why both go).
    * `[:session_ended]` — every other run: the session's end is a fact to report, and what
      happens to the story next is control's to decide from it.
  """
  @spec end_reports(map()) :: [:escalated | :session_ended]
  def end_reports(summary) do
    cond do
      summary[:status] == "deadline_passed" -> []
      summary[:reached] in ["claimed", "worktree"] -> [:escalated]
      summary[:escalations] not in [nil, []] -> [:escalated, :session_ended]
      true -> [:session_ended]
    end
  end

  @doc """
  The `RunnerSessionEnded` for a dispatch whose session is over, validated against the contract.

  The `reason` comes from the run's status alone, so the payload a later Control rebuilds from
  `state.json` is the one this Control composed — a resend with a different reason is refused
  `already_recorded`:

    * `completed` — the session exited 0 on its own (`succeeded`), or ran `loop-escalate`
      (`escalated`). An escalating session also gets its `-> escalated` report, and that report is
      sent FIRST; `session_ended` still follows because the contract calls it "A FACT, not a
      request — control decides the story's next stage from `reason`: `completed` changes
      nothing". So `completed` cannot move a story the escalation just moved, and it is still the
      truth about the session: it stopped because it handed the story to a human.
    * `wall_clock_exceeded`, `max_turns_exceeded` — the run hit that budget (`Session` reports the
      turn budget from the CLI's own `error_max_turns` result line). Its OWN wall clock only: a
      session the dispatch's `deadline_at` stopped first (`stopped_at_deadline`) is `crashed`,
      below. The contract: "`wall_clock_exceeded` and `max_turns_exceeded` escalate an in-flight
      story over the control-only `budget_reported` edge and end its claim", while "`crashed`
      releases the claim at once over `runner_lost` — re-queued below the retry ceiling". A
      deadline stop is loopctl's own placement running out, not a budget the story overran, so
      nothing about it calls for a human, and of the contract's reasons `crashed` is the one that
      releases the claim and places the story again.
    * `crashed` — anything else: a session that exited non-zero on its own, a run that raised or
      died, and the runner's own stops that are no budget (`parked`, `not_group_leader`). The
      contract's `crashed` is "any end the runner did not choose and that is not one of the
      others"; a park is the runner ENDING a session that had already stopped making progress,
      which it did not choose either, and `crashed` is what re-queues such a story rather than
      leaving it to a lease reclaim.

  Since contract 1.27.0 it also carries, each only when known: `turns_used`, the CLI's own
  `num_turns` from its last result line (`StreamEvents.turns/1`), and `work_left_behind`, whether
  the session's branch held commits no `origin` ref reached as it ended
  (`Worktree.work_left_behind/2`). Both are recorded by loopctl with the first copy only, and are
  not part of the report's identity, so a resend that differs in them is still answered `ok`.

  `usage_exhausted` is never sent: nothing the runner reads today tells a session that hit its
  account's usage limit from any other failing exit, so claiming it would be a guess — and it
  releases the claim WITHOUT counting an attempt, which is exactly the guess that must not be
  wrong. Such a session is reported `crashed`.
  """
  @spec session_ended(map(), map()) :: {:ok, map()} | {:error, [String.t()]}
  def session_ended(dispatch, summary) do
    payload =
      %{
        "dispatch_id" => dispatch["dispatch_id"],
        "claim_epoch" => dispatch["claim_epoch"],
        "reason" => session_end_reason(summary)
      }
      |> put_opt("turns_used", turns_used(summary[:turns_used]))
      |> put_opt("work_left_behind", left_behind(summary[:work_left_behind]))

    with :ok <- Contract.validate("RunnerSessionEnded", payload), do: {:ok, payload}
  end

  # Contract 1.27.0's optional facts, each OMITTED when the run could not tell: never a guess, and
  # never a value the schema would refuse the whole report for.
  @max_turns_used Contract.schema_def("RunnerSessionEnded")
                  |> get_in(["properties", "turns_used", "maximum"])

  defp turns_used(n) when is_integer(n) and n >= 0 and n <= @max_turns_used, do: n
  defp turns_used(_n), do: nil

  defp left_behind(value) when is_boolean(value), do: value
  defp left_behind(_value), do: nil

  @budgets ["wall_clock_exceeded", "max_turns_exceeded"]

  defp session_end_reason(%{status: status}) when status in ["succeeded", "escalated"],
    do: "completed"

  defp session_end_reason(%{status: status}) when status in @budgets, do: status
  defp session_end_reason(_summary), do: "crashed"

  @doc """
  How to answer a refusal of a `session_ended`, by its `reason`: `:rate_limited` waits out the
  interval and sends the same bytes again; `:internal_error` is a bounded retry; `:done` is
  `already_recorded` — the dispatch's session end is on record already (with another reason, or
  loopctl would have answered the resend `ok`), so there is nothing left to send; `:permanent` is
  every other reason `x-connection.permanent_errors` names; `:unknown` is anything else, given up
  like a permanent one, since resending on a reason this build does not know is a guess.
  """
  @spec session_ended_refusal(term()) ::
          :rate_limited | :internal_error | :done | :permanent | :unknown
  def session_ended_refusal("rate_limited"), do: :rate_limited
  def session_ended_refusal("internal_error"), do: :internal_error
  def session_ended_refusal("already_recorded"), do: :done
  def session_ended_refusal(reason) when reason in @session_ended_permanent, do: :permanent
  def session_ended_refusal(_reason), do: :unknown

  @doc """
  The reason a run's `-> escalated` report carries (`end_reports/1` says which runs send one): the
  run's outcome — its status, why the session ended, and what the session escalated with if it
  called loop-escalate.
  """
  @spec end_reason(map()) :: String.t()
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
