defmodule LoopctlRunner.SpecTune do
  @moduledoc """
  The runner's half of the improvement loop (US-48.13): a `spec_tune` dispatch (contract 1.30.0)
  read and checked, the context its session is given, and the CRITIC that turns the session's
  proposal into the `spec_tuner@1` result.

  ## The dispatch

  `spec_tune` is the one story-less kind (`LoopctlRunner.DispatchShape`): no `story_id`,
  `claim_epoch` 0, and a `spec_tune` object naming the TARGET spec `{id, version}`, the target's
  TEMPLATE `{id, version}` (the prompt being improved, as loopctl's `Tuning.input/3` sends it —
  never the tuner's own, which the dispatch's kind already names), the eval set `<id>@<version>`
  and the traces. The template is what is fetched and tuned, never a template looked up by the
  target SPEC's `{id, version}`: a spec's version moves on its own while its prompt stays.
  `subject/2` refuses one that names no target, a template this runner does not hold (or the
  tuner itself, which has no eval set), or an eval set that is not the target spec's own;
  `prepare/2` refuses an eval set with no cases. The run is keyed by its `dispatch_id`, never a
  story.

  ## The context (`prepare/2`)

  The runner holds the template text and the cases; loopctl sends neither. The eval set's cases are
  loaded from `eval/<id>@<version>/` (`LoopctlRunner.Eval.Case.load_all/3`, every guard included),
  and the target's CURRENT template text is its prompt as rendered for the first of them
  (`template_text/2`) — a template here is code that renders a prompt from a dispatch, so its text
  is what it renders. An eval set with no cases refuses the run: there is nothing to score against.

  ## The critic (`critique/4`)

  The session states `{new_cases, proposed_template}`. Its new cases carry an `input` (the dispatch
  the case runs, built from the trace), which the result does NOT carry: the contract's case is the
  eval format minus `input`. Before anything is run, every rule loopctl's `Tuning.decide/2` would
  otherwise reject on that the runner can see is checked here, and a proposal that breaks one
  produces NO result: the template named is the target at its current version, going up; every
  case name is new and unique; every `source_trace_id` is a trace the dispatch sent; a case on a
  trace a person decided expects exactly that person's outcomes; and every case loads as a case
  (`Case.from_map/5`, the fixture guard included).

  Then the eval harness is the critic, never the session: the diff is applied to a COPY of the
  current template text (`LoopctlRunner.TextPatch`), and the harness runs every existing case plus
  the new ones twice — as they are, and with the diff applied to each case's rendered prompt
  (`LoopctlRunner.Eval.run_cases/2`'s `:prompt_transform`). A diff that does not apply to the text
  or to any case's prompt produces no result. `scores` is built from those two runs alone, in the
  shape `Tuning.decide/2` recomputes: one `per_case` line per case run, `existing` true for the
  set's own, and `current`/`proposed` totals equal to the number of lines and passes equal to each
  column's count. Whether the proposal is better is loopctl's to decide from those lines; the
  runner sends a proposal that is not, and loopctl records it rejected.

  Nothing here writes a template, a case file or a version: the harness runs in the run's own
  directory, and landing is a pull request a person merges.
  """

  alias LoopctlRunner.{
    AgentResult,
    Contract,
    DispatchRun,
    Eval,
    Templates,
    TextPatch,
    TriageRun,
    Uuid
  }

  alias LoopctlRunner.Eval.Case

  @key {"spec_tuner", 1}

  # The session's block, derived from the contract's result schema rather than typed here: the
  # result's `new_cases` and `proposed_template` exactly, with `input` added to each case — the one
  # field a case needs to RUN and the result never carries.
  {:ok, result_schema} = AgentResult.schema(@key)
  case_schema = get_in(result_schema, ["properties", "new_cases", "items"])

  @stated_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["new_cases", "proposed_template"],
    "properties" => %{
      "new_cases" =>
        Map.put(
          get_in(result_schema, ["properties", "new_cases"]),
          "items",
          case_schema
          |> put_in(["properties", "input"], %{"type" => "object"})
          |> Map.update!("required", &(&1 ++ ["input"]))
        ),
      "proposed_template" => get_in(result_schema, ["properties", "proposed_template"])
    }
  }

  @result_case_keys Map.keys(case_schema["properties"])

  @doc "The key of the spec this module answers for."
  @spec key() :: Templates.key()
  def key, do: @key

  @doc "The schema the session's final block is held to before the critic runs."
  @spec stated_schema() :: map()
  def stated_schema, do: @stated_schema

  @doc """
  What a `spec_tune` dispatch of `template` is run over: `%{"dispatch_id", "spec_tune"}`,
  checked as the moduledoc says. `:none` when the dispatch carries no `spec_tune` object.
  """
  @spec subject(Templates.t(), map()) :: {:ok, map()} | :none | {:error, String.t()}
  def subject(_tuner, %{"spec_tune" => tune} = dispatch) when is_map(tune) do
    with {:ok, target} <- target(tune),
         {:ok, _template} <- template(tune),
         :ok <- eval_set(tune, target),
         :ok <- dispatch_id(dispatch) do
      {:ok, %{"dispatch_id" => String.downcase(dispatch["dispatch_id"]), "spec_tune" => tune}}
    end
  end

  def subject(_tuner, %{"spec_tune" => _}),
    do: {:error, "the spec_tune dispatch's spec_tune object is malformed"}

  def subject(_tuner, _dispatch), do: :none

  # The target SPEC, as loopctl names it. A spec is loopctl's, and its version moves on its own
  # (a budget, a screen) while its prompt stays; so the spec is never looked up as a template here.
  defp target(%{"target" => %{"id" => id, "version" => version}})
       when is_binary(id) and is_integer(version),
       do: {:ok, %{id: id, version: version}}

  defp target(_tune), do: {:error, "the spec_tune dispatch names no target spec"}

  # `spec_tune.template` is the TEMPLATE being tuned — the target spec's prompt, as loopctl sends
  # it (`Loopctl.Agents.Tuning.input/3`: `target.prompt`) — and it is the one fetched: that is the
  # text loopctl means to revise, whatever the spec's own version. Never the tuner's own, which
  # has no eval set and which the dispatch's `kind` already resolved.
  defp template(%{"template" => %{"id" => id, "version" => version}})
       when is_binary(id) and is_integer(version) do
    case Templates.fetch({id, version}) do
      {:ok, %{kind: "spec_tune"}} ->
        {:error,
         "the spec_tune dispatch names template #{id}@#{version}, the tuner itself, which has " <>
           "no eval set"}

      {:ok, template} ->
        {:ok, template}

      :error ->
        {:error, "this runner holds no template #{id}@#{version} to tune"}
    end
  end

  defp template(_tune), do: {:error, "the spec_tune dispatch names no template"}

  # The eval set is the target spec's (`Tuning.eval_set/1`). Whether it holds cases is judged when
  # the run is prepared (`prepare/2`), against the eval directory the critic runs from: an absent
  # or empty set refuses the run there.
  defp eval_set(%{"eval_set" => set}, %{id: id, version: version}) do
    if set == "#{id}@#{version}",
      do: :ok,
      else:
        {:error, "the spec_tune dispatch's eval set #{inspect(set)} is not #{id}@#{version}'s"}
  end

  defp dispatch_id(%{"dispatch_id" => id}) when is_binary(id) do
    if Uuid.valid?(id), do: :ok, else: {:error, "the spec_tune dispatch_id is not a uuid"}
  end

  defp dispatch_id(_dispatch), do: {:error, "the spec_tune dispatch carries no dispatch_id"}

  @doc """
  The context a tuning session is given and its critic runs from: `:target` (the template),
  `:cases` (the eval set's, loaded), `:template_text` and `:text_case` (the current text, as
  rendered for that case), and `:eval_dir`.

  Options: `:eval_dir` (default `eval`, resolved against the runner's working directory, as the
  harness resolves it) and `:scratch_dir` (where a fixture outside the eval directory could
  resolve; the run's own critic directory).
  """
  @spec prepare(map(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def prepare(%{"spec_tune" => tune}, opts) do
    eval_dir = Path.expand(Keyword.get(opts, :eval_dir, "eval"))
    scratch_dir = Keyword.fetch!(opts, :scratch_dir)

    with {:ok, target} <- template(tune),
         {:ok, [first | _] = cases} <- Case.load_all(tune["eval_set"], eval_dir, scratch_dir),
         {:ok, text} <- template_text(target, first.input) do
      {:ok,
       %{
         target: target,
         cases: cases,
         template_text: text,
         text_case: first.name,
         eval_dir: eval_dir
       }}
    end
  end

  @doc """
  `template`'s prompt as rendered for the dispatch `input`, with every value only a live run has —
  the verdict and escalate tokens — as a placeholder. `{:error, reason}` for an input it cannot
  render.
  """
  @spec template_text(Templates.t(), map()) :: {:ok, String.t()} | {:error, String.t()}
  def template_text(%{run: :story} = template, input) do
    case DispatchRun.story_object(input) do
      {:ok, story} ->
        where = %{repo: input["repo"], branch: input["branch"], base: input["base_branch"]}
        {:ok, Templates.render(template, %{story: story, where: Map.put(where, :mode, "pr")})}

      :none ->
        {:error, "the case's input carries no story"}

      {:error, detail} ->
        {:error, detail}
    end
  end

  def template_text(template, input) do
    case TriageRun.subject(template, input) do
      {:ok, subject} ->
        tokens =
          if Templates.agent_result?(template),
            do: :none,
            else: {"<verdict-token>", "<escalate-token>"}

        {:ok, TriageRun.render_prompt(template, subject, input["repo"], tokens)}

      :none ->
        {:error, "the case's input carries no #{template.kind} subject"}

      {:error, detail} ->
        {:error, detail}
    end
  end

  @doc """
  The `spec_tuner@1` result for what the session stated (`stated`, its decoded block), scored by
  the eval harness: `{:ok, result}`, or `{:error, reason}` and nothing is sent. `eval_opts` are
  `LoopctlRunner.Eval.run_cases/2`'s for both passes; `:scratch_dir` and `:results_dir` are given
  a `current`/`proposed` subdirectory each.
  """
  @spec critique(map(), map(), map(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def critique(stated, %{"spec_tune" => tune}, context, eval_opts) do
    with :ok <- stated_shape(stated),
         proposed = stated["proposed_template"],
         :ok <- proposed_template(proposed, context.target),
         :ok <- case_names(stated["new_cases"], context.cases),
         :ok <- case_traces(stated["new_cases"], tune["traces"]),
         {:ok, new_cases} <- load_new_cases(stated["new_cases"], context, eval_opts),
         {:ok, _patched} <- applies(context.template_text, proposed["diff"]),
         cases = context.cases ++ new_cases,
         {:ok, current} <- harness(cases, eval_opts, "current", nil),
         {:ok, scored} <- harness_proposed(cases, eval_opts, proposed["diff"]) do
      {:ok,
       %{
         "new_cases" => Enum.map(stated["new_cases"], &Map.take(&1, @result_case_keys)),
         "proposed_template" => proposed,
         "scores" => scores(context.cases, new_cases, current, scored)
       }}
    end
  end

  defp stated_shape(stated) do
    case Contract.validate_against(@stated_schema, stated, "proposal") do
      :ok ->
        :ok

      {:error, errors} ->
        {:error, "the session's proposal is malformed: " <> Enum.join(errors, "; ")}
    end
  end

  defp proposed_template(%{"id" => id, "from_version" => from, "to_version" => to}, target) do
    cond do
      id != target.id ->
        {:error, "the proposal revises #{id}, not the target #{target.id}"}

      from != target.version ->
        {:error,
         "the proposal revises #{id}@#{from}, not the current #{target.id}@#{target.version}"}

      to <= from ->
        {:error, "the proposal's to_version #{to} does not go up from #{from}"}

      true ->
        :ok
    end
  end

  defp case_names(new_cases, existing) do
    names = Enum.map(new_cases, & &1["name"])
    taken = MapSet.new(existing, & &1.name)

    cond do
      Enum.uniq(names) != names ->
        {:error, "the proposal names one new case twice"}

      (clash = Enum.find(names, &MapSet.member?(taken, &1))) != nil ->
        {:error, "the proposal's case #{clash} has the name of an existing case"}

      true ->
        :ok
    end
  end

  defp case_traces(new_cases, traces) do
    by_id = Map.new(traces, &{String.downcase(&1["trace_id"]), &1})

    Enum.reduce_while(new_cases, :ok, fn c, :ok ->
      case case_trace(c, by_id) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp case_trace(c, by_id) do
    case Map.fetch(by_id, String.downcase(c["source_trace_id"])) do
      :error ->
        {:error, "the proposal's case #{c["name"]} names a trace the dispatch did not send"}

      {:ok, trace} ->
        human_expectation(c, trace)
    end
  end

  # The human's decision IS the expected answer (AC-48.13): a case on a trace a person decided
  # must expect exactly that person's outcomes, never the agent's and never a superset.
  defp human_expectation(c, %{"human_decision" => %{"outcomes" => [_ | _] = outcomes}}) do
    if Enum.sort(c["expectations"]["outcomes_allowed"]) == Enum.sort(outcomes),
      do: :ok,
      else:
        {:error,
         "the proposal's case #{c["name"]} does not expect exactly the outcomes a person decided"}
  end

  defp human_expectation(_case, _trace), do: :ok

  defp load_new_cases(new_cases, context, eval_opts) do
    scratch = Keyword.fetch!(eval_opts, :scratch_dir)

    Enum.reduce_while(new_cases, {:ok, []}, fn c, {:ok, acc} ->
      raw = %{
        "spec" => context.target.id,
        "version" => context.target.version,
        "description" => c["description"],
        "input" => c["input"],
        "fixture" => c["fixture"],
        "expectations" => c["expectations"]
      }

      case Case.from_map(raw, c["name"], "proposed case #{c["name"]}", context.eval_dir, scratch) do
        {:ok, loaded} -> {:cont, {:ok, acc ++ [loaded]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp applies(text, diff) do
    case TextPatch.apply(text, diff) do
      {:ok, patched} ->
        {:ok, patched}

      {:error, why} ->
        {:error, "the proposed diff does not apply to the current template: #{why}"}
    end
  end

  defp harness(cases, eval_opts, pass, transform) do
    opts =
      eval_opts
      |> Keyword.update!(:scratch_dir, &Path.join(&1, pass))
      |> Keyword.update!(:results_dir, &Path.join(&1, pass))
      |> Keyword.put(:prompt_transform, transform)

    case Eval.run_cases(cases, opts) do
      {:ok, results} -> {:ok, Map.new(results, &{&1.name, &1.passed})}
      {:error, reason} -> {:error, "the eval harness refused the #{pass} run: #{reason}"}
    end
  end

  # The proposed pass applies the diff to each case's own rendered prompt. A prompt it does not
  # apply to is recorded, and any one of them means the diff is not a revision of the TEMPLATE —
  # it is an edit of one case's rendering — so the whole proposal produces no result.
  defp harness_proposed(cases, eval_opts, diff) do
    {:ok, refusals} = Agent.start_link(fn -> [] end)

    transform = fn prompt ->
      with {:error, why} = refused <- TextPatch.apply(prompt, diff) do
        Agent.update(refusals, &[why | &1])
        refused
      end
    end

    try do
      with {:ok, scored} <- harness(cases, eval_opts, "proposed", transform) do
        case Agent.get(refusals, & &1) do
          [] ->
            {:ok, scored}

          [why | _] ->
            {:error, "the proposed diff does not apply to every case's prompt: #{why}"}
        end
      end
    after
      Agent.stop(refusals)
    end
  end

  defp scores(existing, new_cases, current, proposed) do
    per_case =
      Enum.map(existing, &line(&1.name, true, current, proposed)) ++
        Enum.map(new_cases, &line(&1.name, false, current, proposed))

    %{
      "current" => %{
        "passed" => Enum.count(per_case, & &1["current"]),
        "total" => length(per_case)
      },
      "proposed" => %{
        "passed" => Enum.count(per_case, & &1["proposed"]),
        "total" => length(per_case)
      },
      "per_case" => per_case
    }
  end

  defp line(name, existing?, current, proposed) do
    %{
      "case" => name,
      "existing" => existing?,
      "current" => Map.fetch!(current, name),
      "proposed" => Map.fetch!(proposed, name)
    }
  end
end
