defmodule Loopctl.Agents.Spec do
  @moduledoc """
  A compiled description of ONE dispatch kind (Epic 48, US-48.2).

  A spec is a struct in a code registry (`Loopctl.Agents.Registry`), never a tenant row, and it
  changes only through code. Its `outcomes`, `screens`, `sweeps` and `effects` decide which
  stage-machine edges and row writes a runner's message can drive, so a spec writable by a key
  could aim an agent-producible outcome at a claim or a human-only edge and let one principal
  both produce and certify. That is the failure the custody model exists to prevent.

  ## Every closed-set field is checked when the spec module COMPILES

  A spec module is written as

      defmodule Loopctl.Agents.Specs.TriageV1 do
        use Loopctl.Agents.Spec,
          id: "triage",
          version: 1,
          archetype: :judge,
          ...
      end

  and `use` evaluates `new!/2` into a module attribute, so a spec with an unknown field, a
  value outside its closed set, or a transition its archetype may not name is a
  `CompileError` naming the field, the value and the archetype. Nothing about a spec is decided
  at run time.

  ## The archetype decides what the agent may do to custody state, not the spec

  | archetype | may name |
  |---|---|
  | `:judge` | CONTROL-ONLY transitions: in `StageMachine.transitions/0`, absent from `StageMachine.runner_transitions/0` |
  | `:draft` | control-only transitions, as `:judge` |
  | `:build` | RUNNER-REPORTABLE transitions only: `StageMachine.runner_transitions/0` |

  and NO spec may name a transition over a human-only edge (`StageMachine.human_only?/1`) —
  that edge is a human's act on an escalation, and nothing an agent produces may aim at it.

  Each named transition is a whole `{from, to, edge}` triple, never an edge alone, because the
  same edge is runner-reportable from one stage and control-only from another: `:forward` from
  `ci` is a runner's merge report, while `:forward` from `detected` is the triage step control
  takes on a verdict.

  Effects follow the same rule one column along: a `:build` spec may name only
  `StageMachine.reportable_effects/0`, a `:judge` spec only the control-written triage binding
  and the drafted story, and a `:draft` spec none (US-48.9 adds its stored artifact).

  What stays code whatever a spec says: claiming and the session-dispatch mint, operator-key
  resolution, the `implementer_dispatch_id` / `triage_dispatch_id` bindings, what
  `session_ended` does to a story, and every L4 custody gate.

  ## Fields

  - `id`, `version` — the spec's name; `{id, version}` is unique in the registry.
  - `archetype` — `:judge | :build | :draft`.
  - `kind` — the dispatch kind, one of `RunnerContract.Kinds.all/0`.
  - `candidates` — `%{predicates: [predicate], order: order}`, from the closed set
    `Loopctl.Agents.Candidates` builds the candidate read from.
  - `sweeps` — `%{sweep => route}`: control passes that finish a half-taken story.
  - `payload` — the payload builder the dispatch carries.
  - `refs` — for each `RunnerDispatch.ref_fields/0` key, where its value comes from.
  - `runner` — the eligibility facts a runner must satisfy before the dispatch is written.
  - `advance_on` — the placement refusals on which a `:build` pass tries the story's NEXT
    selected runner instead of stopping (US-48.7). Only a refusal about the MACHINE that is
    decided before anything is minted may be named, and only a `:build` spec may name any: a
    `:judge` pass sends to the first runner `Selection.runners/3` returns and nothing else.
  - `budgets` — the `{wall_clock_key, max_turns_key}` config pair.
  - `result` — the runner messages the session answers with.
  - `screens` — `%{screen => route}`: the route each control screen takes when it refuses.
  - `outcomes` — `%{outcome => route}`: what each result outcome drives.
  - `effects` — the row writes the result drives.
  - `rerun` — what happens to a story whose dispatch did not produce a result.
  - `concurrency` — what keeps a second dispatch from going out for the same story.
  - `prompt` — `{template_id, version}` of the runner-held template. A dispatch never carries
    prose; the runner holds the template.

  A route is a non-empty list of `{from, to, edge}` transitions: taken in order for a judge's
  outcome, a screen or a sweep, and the set a single report may carry for a build's `stage`
  result (one transition per message).
  """

  alias Loopctl.Agents.Candidates
  alias Loopctl.Agents.Registry
  alias Loopctl.ApiSpec.RunnerContract
  alias Loopctl.Delivery.StageMachine

  @fields [
    :id,
    :version,
    :archetype,
    :kind,
    :candidates,
    :sweeps,
    :payload,
    :refs,
    :runner,
    :advance_on,
    :budgets,
    :result,
    :screens,
    :outcomes,
    :effects,
    :rerun,
    :concurrency,
    :prompt
  ]

  @enforce_keys @fields
  defstruct @fields

  @type archetype :: :judge | :build | :draft
  @type route :: [StageMachine.transition()]

  @type t :: %__MODULE__{
          id: String.t(),
          version: pos_integer(),
          archetype: archetype(),
          kind: String.t(),
          candidates: Candidates.candidates(),
          sweeps: %{optional(atom()) => route()},
          payload: atom(),
          refs: keyword(atom()),
          runner: [atom()],
          advance_on: [atom()],
          budgets: {atom(), atom()},
          result: [String.t()],
          screens: %{optional(atom()) => route()},
          outcomes: %{optional(String.t()) => route()},
          effects: [atom()],
          rerun: atom(),
          concurrency: atom(),
          prompt: {String.t(), pos_integer()}
        }

  @archetypes [:judge, :build, :draft]

  # The candidate predicates and their ranking are `Loopctl.Agents.Candidates`' closed set
  # (US-48.3): that module builds the read from them, and its `validate/1` is the check here.

  # `TriageDispatcher.stranded/1`: a story at `triaged` with no verdict, no binding and no live
  # dispatch, left there by the too-large route's second transaction failing.
  @sweeps [:stranded_triaged_unbound]

  # `TriagePayload.build/1` (the reporter's words, fenced) and `StoryPayload` /
  # `ImplementerInput.story_object/2` (a `RunnerStory`).
  @payloads [:triage_payload, :story_payload]

  # Where each ref field's value comes from.
  @ref_sources [
    # The intake source's `base_branch`, checked with `GitRef.valid_name?/1`.
    :source_base_branch,
    # Derived per story from the TARGET runner's `branch_prefixes` (`DispatchPayload.fill/3`).
    :story_branch_for_runner_prefixes
  ]

  # The eligibility facts decided BEFORE the ledger row is written (`Runners.Selection`,
  # `Runners.accepts?/5`, `Runners.Capacity.admit/2`).
  @runner_facts [
    :connected,
    :not_draining,
    :repo_declared,
    :kind_declared,
    :free_slot,
    :subscription_not_exhausted,
    :tenant_admission_headroom
  ]

  # The placement refusals a `:build` pass may advance past to the story's next runner
  # (`Loopctl.Agents.Dispatcher`). Both are about the MACHINE and both are decided by
  # `Placement.place/4` before anything is minted, so a refused attempt has written nothing:
  #
  # - `:runner_exhausted` — the machine ran dry after selection; passed over WITHOUT becoming
  #   the answer, so a story every selected machine was dry for is `:no_runner`.
  # - `:no_conforming_branch` — the machine's `branch_prefixes` can produce no valid branch;
  #   advanced past AND kept as the answer, so a pass on which every machine is misconfigured
  #   still reports the state that needs a person.
  #
  # Every other refusal concerns the story (the next machine would answer identically) or has
  # already spent something, so advancing on it would loop or compensate once per runner.
  @advance_refusals [:runner_exhausted, :no_conforming_branch]

  # The config pairs `DispatchDriver.normalise_budget/2` has a ceiling for.
  @budget_pairs [
    {:triage_wall_clock_seconds, :triage_max_turns},
    {:dispatch_wall_clock_seconds, :dispatch_max_turns}
  ]

  # Runner messages a session answers with (`RunnerContract.inbound_events/0`).
  @results ["triage_verdict", "stage", "session_ended"]

  @screens [
    # `TriagePayload.build/1` refusing a ticket whose rendered object exceeds the contract.
    :payload_too_large,
    # `TriageVerdict`'s gate screen (US-44.2): Gate A over the lens verdicts, Gate B over the
    # predicted touches.
    :gate_a,
    :gate_b,
    # `TriageVerdict`'s `:draft_injection` screen: the drafted story scanned for
    # `draft_signals/0`.
    :draft_injection,
    # `TriageVerdict`'s `:draft_dispatchable` screen: the draft judged as a dispatch will judge
    # it.
    :draft_dispatchable,
    # `StoryPayload.build/3` parking a story the contract cannot describe.
    :story_not_dispatchable
  ]

  # Row writes a result can drive: the stage machine's side-effect identities plus the drafted
  # story row `TriageVerdict` writes.
  @effects StageMachine.effects() ++ [:story_draft]

  @archetype_effects %{
    judge: [:triage_dispatch_id, :story_draft],
    build: StageMachine.reportable_effects(),
    draft: []
  }

  @reruns [
    # Nothing is retried or remembered: a story the pass could not dispatch, or whose session
    # died, is a candidate again on a later pass once its ledger row releases.
    :next_pass,
    # A released claim re-queues the story until its counted releases reach
    # `DISPATCH_MAX_ATTEMPTS` (`Loopctl.Delivery.RetryCeiling`).
    :requeue_until_retry_ceiling
  ]

  @concurrency [
    # `:no_unreleased_dispatch_of_kind` in the candidate read.
    :one_unreleased_dispatch_per_story,
    # The story's claim: one implementer at a time.
    :one_claim_per_story
  ]

  # A function, not an attribute: an OTP 28 regex cannot be escaped into a module attribute.
  defp id_format, do: ~r/\A[a-z][a-z0-9_]*\z/

  @doc false
  defmacro __using__(fields) do
    quote do
      @agent_spec Loopctl.Agents.Spec.new!(unquote(fields), __ENV__)

      @doc "This module's compiled `Loopctl.Agents.Spec`."
      @spec spec() :: Loopctl.Agents.Spec.t()
      def spec, do: @agent_spec
    end
  end

  @doc """
  Builds a spec from `fields`, or raises `CompileError` at `env`'s file and line.

  Called by `use Loopctl.Agents.Spec` while the spec module compiles, which is what makes a bad
  spec a build failure rather than a run-time one.
  """
  @spec new!(keyword(), Macro.Env.t()) :: t()
  def new!(fields, %Macro.Env{} = env) when is_list(fields) do
    case validate(fields) do
      {:ok, spec} ->
        spec

      {:error, message} ->
        raise CompileError, file: env.file, line: env.line, description: message
    end
  end

  @doc """
  Every transition `spec` names, from its outcomes, screens and sweeps, deduplicated.
  """
  @spec named_transitions(t() | map()) :: [StageMachine.transition()]
  def named_transitions(%{outcomes: outcomes, screens: screens, sweeps: sweeps}) do
    [outcomes, screens, sweeps]
    |> Enum.flat_map(&Map.values/1)
    |> List.flatten()
    |> Enum.uniq()
  end

  @doc """
  The transitions a spec of `archetype` may name. See the moduledoc's table.
  """
  @spec allowed_transitions(archetype()) :: [StageMachine.transition()]
  def allowed_transitions(:build), do: StageMachine.runner_transitions()

  def allowed_transitions(archetype) when archetype in [:judge, :draft] do
    for {_from, _to, edge} = transition <- StageMachine.transitions(),
        transition not in StageMachine.runner_transitions(),
        not StageMachine.human_only?(edge),
        do: transition
  end

  @doc "The effects a spec of `archetype` may name."
  @spec allowed_effects(archetype()) :: [atom()]
  def allowed_effects(archetype), do: Map.fetch!(@archetype_effects, archetype)

  @doc "The archetypes."
  @spec archetypes() :: [archetype()]
  def archetypes, do: @archetypes

  @doc """
  Every screen name a spec may give a route: the closed set its `screens` keys are checked
  against when it compiles. `triage@1`'s are run by the code that names them:
  `Loopctl.Agents.Dispatcher` (`:payload_too_large`) and `Loopctl.Delivery.TriageVerdict`
  (`TriageVerdict.screens/0`, US-48.5).
  """
  @spec screen_names() :: [atom()]
  def screen_names, do: @screens

  @doc """
  Every effect name a spec may list: the closed set its `effects` are checked against when it
  compiles, before the archetype narrows it (`allowed_effects/1`).
  """
  @spec effect_names() :: [atom()]
  def effect_names, do: @effects

  @doc """
  Whether a dispatch HOLDS A CLAIM on its story: its spec's archetype is `:build` (US-48.6).

  THE ONE READING of "is this an implement session", for every path that must refuse a session
  of another kind a claim to report on, a fence on epoch or story, or a resume. Takes a spec,
  or a dispatch kind as a ledger row or a payload carries it:

  - a kind a spec describes answers for that spec's archetype;
  - `nil` is `Loopctl.Agents.Registry.default_kind/0`: a ledger row written before `kind`
    existed, when the implement dispatch was the only one sent;
  - any other value holds NO claim. Failing closed is the point: a kind no spec describes was
    never meant to claim a story, and reading it as one is what would let it.
  """
  @spec holds_claim?(t() | String.t() | nil) :: boolean()
  def holds_claim?(%__MODULE__{archetype: archetype}), do: archetype == :build
  def holds_claim?(nil), do: holds_claim?(Registry.default_kind())

  def holds_claim?(kind) when is_binary(kind) do
    case Registry.for_kind(kind) do
      {:ok, spec} -> holds_claim?(spec)
      {:error, :unknown_kind} -> false
    end
  end

  def holds_claim?(_not_a_kind), do: false

  # ── validation ──────────────────────────────────────────────────────────────────────────────

  defp validate(fields) do
    with :ok <- exact_fields(fields),
         spec = struct!(__MODULE__, fields),
         :ok <- check_identity(spec),
         :ok <- check_closed_sets(spec),
         :ok <- check_routes(spec),
         :ok <- check_archetype_transitions(spec),
         :ok <- check_archetype_effects(spec),
         :ok <- check_archetype_advance(spec) do
      {:ok, spec}
    end
  end

  defp exact_fields(fields) do
    keys = Keyword.keys(fields)
    # `--` removes ONE occurrence per element, so a duplicated known field would otherwise be
    # reported as unknown.
    unknown = Enum.uniq(keys) -- @fields
    missing = @fields -- keys
    duplicated = keys -- Enum.uniq(keys)

    cond do
      unknown != [] -> {:error, "agent spec: unknown field(s) #{inspect(unknown)}"}
      missing != [] -> {:error, "agent spec: missing field(s) #{inspect(missing)}"}
      duplicated != [] -> {:error, "agent spec: duplicated field(s) #{inspect(duplicated)}"}
      true -> :ok
    end
  end

  defp check_identity(%__MODULE__{id: id, version: version, prompt: prompt}) do
    cond do
      not (is_binary(id) and Regex.match?(id_format(), id)) ->
        {:error, "agent spec: id #{inspect(id)} must match #{inspect(Regex.source(id_format()))}"}

      not (is_integer(version) and version > 0) ->
        {:error, "agent spec #{id}: version #{inspect(version)} must be a positive integer"}

      not valid_prompt?(prompt) ->
        {:error,
         "agent spec #{id}@#{version}: prompt #{inspect(prompt)} must be " <>
           "{template_id, version} with a template id matching " <>
           "#{inspect(Regex.source(id_format()))} and a positive integer version"}

      true ->
        :ok
    end
  end

  defp valid_prompt?({template_id, version}),
    do:
      is_binary(template_id) and Regex.match?(id_format(), template_id) and is_integer(version) and
        version > 0

  defp valid_prompt?(_prompt), do: false

  defp check_closed_sets(spec) do
    label = label(spec)

    checks = [
      one_of(label, :archetype, spec.archetype, @archetypes),
      one_of(label, :kind, spec.kind, RunnerContract.Kinds.all()),
      candidates(label, spec.candidates),
      keys_of(label, :sweeps, spec.sweeps, @sweeps),
      one_of(label, :payload, spec.payload, @payloads),
      refs(label, spec.refs),
      subset_of(label, :runner, spec.runner, @runner_facts, non_empty: true),
      subset_of(label, :advance_on, spec.advance_on, @advance_refusals, non_empty: false),
      one_of(label, :budgets, spec.budgets, @budget_pairs),
      subset_of(label, :result, spec.result, @results, non_empty: true),
      keys_of(label, :screens, spec.screens, @screens),
      outcomes(label, spec.outcomes),
      subset_of(label, :effects, spec.effects, @effects, non_empty: false),
      one_of(label, :rerun, spec.rerun, @reruns),
      one_of(label, :concurrency, spec.concurrency, @concurrency)
    ]

    Enum.find(checks, :ok, &(&1 != :ok))
  end

  defp one_of(label, field, value, allowed) do
    if value in allowed,
      do: :ok,
      else: {:error, "#{label}: #{field} #{inspect(value)} is not one of #{inspect(allowed)}"}
  end

  defp subset_of(label, field, values, allowed, non_empty: non_empty?) do
    cond do
      not is_list(values) ->
        {:error, "#{label}: #{field} must be a list, got #{inspect(values)}"}

      non_empty? and values == [] ->
        {:error, "#{label}: #{field} must name at least one of #{inspect(allowed)}"}

      Enum.uniq(values) != values ->
        {:error, "#{label}: #{field} names a value twice: #{inspect(values)}"}

      (unknown = values -- allowed) != [] ->
        {:error, "#{label}: #{field} #{inspect(unknown)} not in #{inspect(allowed)}"}

      true ->
        :ok
    end
  end

  defp keys_of(label, field, map, allowed) when is_map(map),
    do: subset_of(label, field, Map.keys(map), allowed, non_empty: false)

  defp keys_of(label, field, value, _allowed),
    do: {:error, "#{label}: #{field} must be a map, got #{inspect(value)}"}

  defp candidates(label, candidates) do
    case Candidates.validate(candidates) do
      :ok -> :ok
      {:error, message} -> {:error, "#{label}: #{message}"}
    end
  end

  # Exactly the contract's ref fields, each with a known source.
  defp refs(label, refs) do
    ref_fields = Keyword.keys(RunnerContract.RunnerDispatch.ref_fields())

    cond do
      not Keyword.keyword?(refs) or Enum.sort(Keyword.keys(refs)) != Enum.sort(ref_fields) ->
        {:error, "#{label}: refs must name exactly #{inspect(ref_fields)}, got #{inspect(refs)}"}

      (bad = for({field, source} <- refs, source not in @ref_sources, do: field)) != [] ->
        {:error, "#{label}: refs #{inspect(bad)} name a source not in #{inspect(@ref_sources)}"}

      true ->
        :ok
    end
  end

  defp outcomes(label, outcomes) when is_map(outcomes) and map_size(outcomes) > 0 do
    case Enum.reject(Map.keys(outcomes), &(is_binary(&1) and Regex.match?(id_format(), &1))) do
      [] -> :ok
      bad -> {:error, "#{label}: outcome names #{inspect(bad)} must be lower-case strings"}
    end
  end

  defp outcomes(label, value),
    do: {:error, "#{label}: outcomes must be a non-empty map of routes, got #{inspect(value)}"}

  # Every route is a non-empty list of transitions the stage machine HAS. A transition outside
  # the table is refused here, before the archetype check, so the message says which it is.
  defp check_routes(spec) do
    label = label(spec)

    routes =
      for {field, map} <- [outcomes: spec.outcomes, screens: spec.screens, sweeps: spec.sweeps],
          {name, route} <- map,
          do: {"#{field}.#{name}", route}

    Enum.find_value(routes, :ok, fn {where, route} -> route_error(label, where, route) end)
  end

  defp route_error(label, where, route) when is_list(route) and route != [] do
    case Enum.reject(route, &(&1 in StageMachine.transitions())) do
      [] ->
        nil

      bad ->
        {:error, "#{label}: #{where} names #{inspect(bad)}, not in StageMachine.transitions/0"}
    end
  end

  defp route_error(label, where, route),
    do:
      {:error,
       "#{label}: #{where} must be a non-empty list of transitions, got #{inspect(route)}"}

  # THE CUSTODY CHECK. Human-only first, whatever the archetype, so the message names the rule
  # that actually binds: no spec may aim anything at a human's edge.
  defp check_archetype_transitions(spec) do
    label = label(spec)
    allowed = allowed_transitions(spec.archetype)

    Enum.find_value(named_transitions(spec), :ok, fn {_from, _to, edge} = transition ->
      cond do
        StageMachine.human_only?(edge) ->
          {:error,
           "#{label} (archetype #{inspect(spec.archetype)}) names #{inspect(transition)} over " <>
             "the human_only edge #{inspect(edge)}; no spec may name a human_only edge"}

        transition not in allowed ->
          {:error,
           "#{label} (archetype #{inspect(spec.archetype)}) names #{inspect(transition)}, " <>
             "which a #{inspect(spec.archetype)} spec may not name: " <>
             archetype_rule(spec.archetype)}

        true ->
          nil
      end
    end)
  end

  defp archetype_rule(:build), do: "a :build spec may name only runner-reportable transitions"

  defp archetype_rule(archetype),
    do: "a #{inspect(archetype)} spec may name only control-only transitions"

  defp check_archetype_effects(spec) do
    case spec.effects -- allowed_effects(spec.archetype) do
      [] ->
        :ok

      bad ->
        {:error,
         "#{label(spec)} (archetype #{inspect(spec.archetype)}) names effect(s) #{inspect(bad)}; " <>
           "a #{inspect(spec.archetype)} spec may name only " <>
           inspect(allowed_effects(spec.archetype))}
    end
  end

  # Advancing to another runner is a PLACEMENT's answer, so only a spec that places may name a
  # refusal to advance on.
  defp check_archetype_advance(%__MODULE__{archetype: :build}), do: :ok
  defp check_archetype_advance(%__MODULE__{advance_on: []}), do: :ok

  defp check_archetype_advance(spec),
    do:
      {:error,
       "#{label(spec)} (archetype #{inspect(spec.archetype)}) names advance_on " <>
         "#{inspect(spec.advance_on)}; only a :build spec places, so only a :build spec " <>
         "may advance to another runner"}

  defp label(%__MODULE__{id: id, version: version}), do: "agent spec #{id}@#{version}"
end
