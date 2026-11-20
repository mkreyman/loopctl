defmodule LoopctlRunner.Templates do
  @moduledoc """
  The runner's template registry (US-48.8): what this runner holds for each agent spec loopctl
  dispatches, keyed `{id, version}` as loopctl keys its specs (`Loopctl.Agents.Registry`).

  A template is this runner's half of a spec: the KIND its dispatch arrives as, the ARCHETYPE that
  says what the run may do (`:judge`, `:build` or `:draft`, loopctl's three, mirrored here), how
  the accepted dispatch is run, which event carries its result, and the prompt it renders. The
  prompt's structure and every instruction in it are this runner's, never loopctl's: a dispatch
  carries typed fields only, because a control plane able to hand a runner prose could run
  anything on it.

  `implement@1` and `triage@1` are today's two prompts, unchanged (`LoopctlRunner.DispatchPrompt`
  and `LoopctlRunner.TriagePrompt`); `test/loopctl_runner/templates_test.exs` holds both,
  byte for byte, against goldens captured from the builders before the registry existed.
  `reply_draft@1` (US-48.9, `LoopctlRunner.ReplyDraftPrompt`) is the first template written for a
  spec rather than transcribed from a kind, and is held to a golden the same way, as is
  `verify@1` (US-48.18, `LoopctlRunner.VerifyPrompt`) and `spec_tuner@1` (US-48.13,
  `LoopctlRunner.SpecTunerPrompt`).

  ## This runner never edits a template

  `spec_tuner@1` proposes a revision of another template as a diff, and the runner scores it by
  applying that diff to a COPY of each rendered prompt (`LoopctlRunner.TextPatch`). Nothing in
  this registry, its prompt modules or the eval cases is ever written at run time: a new template
  version lands only as a pull request a person merges (PRD default, US-48.13).

  ## Which template a dispatch runs

  A dispatch names its `kind`, and nothing else on the wire names a spec yet, so a dispatch of
  kind `K` runs `K@1` (`for_dispatch/1`) — which is also how loopctl reads a runner that declares
  no `specs` (AC-48.8.1). A `{id, version}` this runner does not hold is `:error`, and
  `LoopctlRunner.Control` refuses that dispatch `other` through the same clause that refuses a
  declared kind with no accept path: never `kind_not_supported`, which is a capability statement
  only `Control.declared_kind/1` makes.

  ## The archetype decides the branch-prefix exemption

  Only a `:build` run cuts, writes and pushes its `branch`, so only a `:build` dispatch is held to
  this machine's `branch_prefixes` (`LoopctlRunner.DispatchPolicy`). A `:judge` run (triage) works
  on a detached tree and loopctl names the base as its `branch`; a `:draft` run stores an artifact
  and binds nothing. Both keep the plain-ref check.
  """

  alias LoopctlRunner.{
    DispatchPrompt,
    ReplyDraftPrompt,
    SpecTunerPrompt,
    TriagePrompt,
    VerifyPrompt
  }

  @typedoc "loopctl's three archetypes (`Loopctl.Agents.Spec.archetype/0`)."
  @type archetype :: :judge | :build | :draft

  @type key :: {String.t(), pos_integer()}

  @typedoc """
  A registry entry. `run` names the accept path `Control.work/3` builds the work from: `:story`
  for a run on a worktree of its own branch, `:triage` for a session over a fenced report on a
  detached tree — a `:judge`'s verdict or a `:draft`'s artifact, which `LoopctlRunner.TriageRun`
  tells apart by the archetype.
  """
  @type t :: %{
          id: String.t(),
          version: pos_integer(),
          kind: String.t(),
          archetype: archetype(),
          run: :story | :triage,
          result_event: String.t()
        }

  @archetypes [:judge, :build, :draft]

  # `result_event` is the event the run's RESULT goes back over, as `x-connection.events` names it:
  # a :build run's result is its stage reports and its `session_ended`, a :judge run's is its
  # verdict. See `result_event/1`.
  @templates %{
    {"implement", 1} => %{
      id: "implement",
      version: 1,
      kind: "implement",
      archetype: :build,
      run: :story,
      result_event: "session_ended"
    },
    {"triage", 1} => %{
      id: "triage",
      version: 1,
      kind: "triage",
      archetype: :judge,
      run: :triage,
      result_event: "triage_verdict"
    },
    # US-48.9, the first `:draft`. Its run is triage's (`run: :triage`): the same payload (the
    # fenced report, contract 1.26.0), the same detached tree, the same budgets and deadline, so the
    # same accept path and the same `TriageRun`. What the archetype changes is inside that run —
    # the prompt, a read-only argv, and a result read from the session's final message — and the
    # event it goes back over, `agent_result`, the one `:draft` has no kind-specific event for.
    {"reply_draft", 1} => %{
      id: "reply_draft",
      version: 1,
      kind: "reply_draft",
      archetype: :draft,
      run: :triage,
      result_event: "agent_result"
    },
    # US-48.18. A `:judge` like triage, but of a PULL REQUEST: its dispatch carries the story and
    # `verify` (`{pr_number, head_sha}`, contract 1.28.0) rather than a report, and its run cuts the
    # detached tree at that head (fetched first) rather than at the checkout's commit. Like a
    # `:draft` it answers with the generic `agent_result` — loopctl applies the verdict under its
    # own verifier dispatch, so the session holds no key and stages nothing. `branch` is the pull
    # request's own, which the session reads and never writes: a `:judge` is prefix-exempt.
    {"verify", 1} => %{
      id: "verify",
      version: 1,
      kind: "verify",
      archetype: :judge,
      run: :triage,
      result_event: "agent_result"
    },
    # US-48.13, the improvement loop, and the one template whose id is not its kind: loopctl's
    # spec is `spec_tuner@1` and the dispatch that runs it is a `spec_tune` (contract 1.30.0), the
    # one story-less kind. A `:draft` on triage's detached-tree path, answered by `agent_result`;
    # what makes its result is not the session but the eval harness the runner runs after it
    # (`LoopctlRunner.SpecTune`), so a proposal is scored by an external critic, never by itself.
    {"spec_tuner", 1} => %{
      id: "spec_tuner",
      version: 1,
      kind: "spec_tune",
      archetype: :draft,
      run: :triage,
      result_event: "agent_result"
    }
  }

  for {{id, version}, entry} <- @templates do
    unless entry.id == id and entry.version == version and entry.archetype in @archetypes and
             id =~ ~r/\A[a-z][a-z0-9_]*\z/ and byte_size(id) <= 64 and is_integer(version) and
             version >= 1 do
      raise "template #{id}@#{version} is malformed: its key, id, version or archetype disagree"
    end
  end

  @doc "loopctl's three archetypes."
  @spec archetypes() :: [archetype()]
  def archetypes, do: @archetypes

  @doc "Every template this runner holds, ordered by id then version."
  @spec all() :: [t()]
  def all, do: @templates |> Map.values() |> Enum.sort_by(&{&1.id, &1.version})

  @doc "The template for `{id, version}`, or `:error` when this runner holds none."
  @spec fetch(key()) :: {:ok, t()} | :error
  def fetch(key), do: Map.fetch(@templates, key)

  # Every kind runs exactly one template at version 1, so the kind names its template without
  # ambiguity. Checked here, at compile time, because two templates claiming one kind would make
  # `for_dispatch/1` pick between them.
  @by_kind for t <- Map.values(@templates), t.version == 1, into: %{}, do: {t.kind, t}

  unless map_size(@by_kind) ==
           Enum.count(Map.values(@templates), &(&1.version == 1)) do
    raise "two version-1 templates claim one dispatch kind"
  end

  @doc """
  The template a dispatch runs: version 1 of the template whose `kind` is the dispatch's, since a
  dispatch names no spec of its own yet. That is `{kind, 1}` for every kind but `spec_tune`,
  whose spec is `spec_tuner@1`. `:error` for a dispatch with no string kind or one this runner
  holds no template for.
  """
  @spec for_dispatch(map()) :: {:ok, t()} | :error
  def for_dispatch(%{"kind" => kind}) when is_binary(kind), do: Map.fetch(@by_kind, kind)
  def for_dispatch(_dispatch), do: :error

  @doc """
  Whether a dispatch is exempt from this machine's branch prefixes: its template's archetype
  writes no branch (anything but `:build`). A dispatch with no template is never exempt.
  """
  @spec prefix_exempt?(map()) :: boolean()
  def prefix_exempt?(dispatch) do
    case for_dispatch(dispatch) do
      {:ok, %{archetype: archetype}} -> archetype != :build
      :error -> false
    end
  end

  @doc """
  The `specs` a join declares for `kinds`: every template whose kind is declared, as
  `[%{"id" => id, "version" => version}]`, ordered by id then version.
  """
  @spec specs([String.t()]) :: [%{String.t() => String.t() | pos_integer()}]
  def specs(kinds) do
    for %{kind: kind} = template <- all(),
        kind in kinds,
        do: %{"id" => template.id, "version" => template.version}
  end

  @doc """
  What a join adds for `kinds`, given the vendored `RunnerJoin` definition: `%{"specs" => ...}`
  when that definition declares the field (contract 1.25.0), `%{}` when it does not.

  Gated on the contract rather than sent regardless because a field the vendored definition does
  not name is a field `Contract.validate/2` cannot check: 1.24.0's `RunnerJoin` allows unknown
  properties, so `specs` would pass unvalidated and reach a server that drops it. Sent only once
  the vendored copy names it, every byte of it is validated before it goes.
  """
  @spec join_field([String.t()], map()) :: map()
  def join_field(kinds, join_definition) do
    if Map.has_key?(Map.get(join_definition, "properties", %{}), "specs"),
      do: %{"specs" => specs(kinds)},
      else: %{}
  end

  @doc """
  THE SEAM where a template's result event is chosen. implement@1 keeps its stage reports ending
  in `session_ended` and triage@1 its `triage_verdict`; reply_draft@1, a `:draft` with no event of
  its own, sends the generic `agent_result` (US-48.9), and so does verify@1 (US-48.18), whose
  verdict loopctl applies through its own verifier dispatch.
  """
  @spec result_event(t()) :: String.t()
  def result_event(%{result_event: event}), do: event

  @doc """
  Renders `template`'s prompt from its inputs:

    * implement@1 — `%{story: story_object, where: %{repo, branch, base, mode, rework}}`
      (`DispatchPrompt.build/2`), `rework` being the dispatch's (contract 1.31.0) or `nil`;
    * triage@1 — `%{triage: triage_object, repo: repo, opts: opts}` (`TriagePrompt.build/3`);
    * reply_draft@1 — `%{triage: triage_object, repo: repo}` (`ReplyDraftPrompt.build/2`);
    * verify@1 — `%{verify: subject, repo: repo, opts: opts}` (`VerifyPrompt.build/3`), the
      subject being `LoopctlRunner.TriageRun.subject/2`'s for a verify dispatch;
    * spec_tuner@1 — `%{spec_tune: subject, repo: repo, context: context}`
      (`SpecTunerPrompt.build/3`), the context being `LoopctlRunner.SpecTune.prepare/2`'s: the
      target template's current text and its eval cases.
  """
  @spec render(t(), map()) :: String.t()
  def render(%{id: "implement", version: 1}, %{story: story, where: where}),
    do: DispatchPrompt.build(story, where)

  def render(%{id: "triage", version: 1}, %{triage: triage, repo: repo, opts: opts}),
    do: TriagePrompt.build(triage, repo, opts)

  def render(%{id: "reply_draft", version: 1}, %{triage: triage, repo: repo}),
    do: ReplyDraftPrompt.build(triage, repo)

  def render(%{id: "verify", version: 1}, %{verify: subject, repo: repo, opts: opts}),
    do: VerifyPrompt.build(subject, repo, opts)

  def render(%{id: "spec_tuner", version: 1}, %{spec_tune: subject, repo: repo, context: context}),
      do: SpecTunerPrompt.build(subject, repo, context)

  @doc """
  Whether `template`'s result is read from its session's final message and sent as
  `agent_result` (reply_draft@1, verify@1) rather than stated by a command (triage@1's
  `loop-verdict`) or reported as stages (implement@1).
  """
  @spec agent_result?(t()) :: boolean()
  def agent_result?(%{result_event: "agent_result"}), do: true
  def agent_result?(_template), do: false
end
