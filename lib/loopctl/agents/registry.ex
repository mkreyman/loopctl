defmodule Loopctl.Agents.Registry do
  @moduledoc """
  The agent specs, in code (Epic 48, US-48.2).

  There is no table and no API behind this: a spec changes only through a code change, because
  its outcomes and effects decide which custody edges a runner message can drive (see
  `Loopctl.Agents.Spec`). Per-tenant data is limited to knobs that cannot move authority.

  Read for each spec's `candidates`: `TriageDispatcher.candidates/1` and
  `DispatchDriver.candidates/1` are `Loopctl.Agents.Candidates.query/2` over their spec
  (US-48.3). The triage dispatch pass runs from `triage@1` through `Loopctl.Agents.Dispatcher`
  (US-48.4), and so does the implement pass from `implement@1` (US-48.7). The triage result is
  routed from `triage@1` by `Loopctl.Delivery.TriageVerdict` (US-48.5). Read for each kind's
  archetype and budgets (US-48.6): `Spec.holds_claim?/1` is the one claim-holding predicate
  the dispatch ledger and `Placement` ask — including `Placement.place/4`'s refusal of a kind
  that is not a `:build` — and
  `DispatchPayload.budget_keys/1` reads the spec's `budgets`. `reply_draft@1` (US-48.9) is the
  first spec that is not a transcription: its `:draft` pass runs through the same
  `Loopctl.Agents.Dispatcher`, from `Loopctl.Workers.ReplyDraftDispatchWorker`, and its result
  through `Loopctl.Agents.AgentResult`. `verify@1` (US-48.18) is a `:judge` whose pass runs
  through the same `Dispatcher`, from `Loopctl.Workers.VerifyDispatchWorker`, but places each
  candidate through `Loopctl.Agents.VerifierPlacement` (a verifier dispatch rooted apart from
  the implementer's), and whose verdict is applied by `Loopctl.Agents.VerifyVerdict`. Later
  stories move the rest of
  each dispatch kind onto its spec, each with an
  equivalence test; until then `Loopctl.Agents.RegistryTest` binds the registry to the lists it
  must agree with — `RunnerContract.Kinds.all/0`, the `runner_dispatches_kind` CHECK,
  `TriageVerdict`'s routes and `StageMachine.transitions/0` —
  and names the modules allowed to read it.

  `{id, version}` is unique, and so is `kind`: one spec per dispatch kind today. Both are
  checked when this module compiles.
  """

  alias Loopctl.Agents.Spec
  alias Loopctl.Agents.Specs

  @modules [
    Specs.TriageV1,
    Specs.ImplementV1,
    Specs.ReplyDraftV1,
    Specs.VerifyV1,
    Specs.SpecTunerV1
  ]

  @specs Enum.map(@modules, & &1.spec())

  for {label, key} <- [{"{id, version}", &{&1.id, &1.version}}, {"kind", & &1.kind}] do
    keys = Enum.map(@specs, key)
    duplicated = keys -- Enum.uniq(keys)

    if duplicated != [] do
      raise ArgumentError,
            "Loopctl.Agents.Registry: #{label} not unique: #{inspect(duplicated)}"
    end
  end

  @doc "Every spec, in registry order."
  @spec all() :: [Spec.t()]
  def all, do: @specs

  @doc "The spec named `id` at `version`."
  @spec fetch(String.t(), pos_integer()) :: {:ok, Spec.t()} | {:error, :unknown_spec}
  def fetch(id, version) do
    case Enum.find(@specs, &(&1.id == id and &1.version == version)) do
      nil -> {:error, :unknown_spec}
      spec -> {:ok, spec}
    end
  end

  @doc "The spec for dispatch `kind`."
  @spec for_kind(String.t()) :: {:ok, Spec.t()} | {:error, :unknown_kind}
  def for_kind(kind) do
    case Enum.find(@specs, &(&1.kind == kind)) do
      nil -> {:error, :unknown_kind}
      spec -> {:ok, spec}
    end
  end

  @doc "Every dispatch kind a spec describes, sorted."
  @spec kinds() :: [String.t()]
  def kinds, do: @specs |> Enum.map(& &1.kind) |> Enum.sort()

  # implement@1's kind: the one dispatch there was before a dispatch carried `kind` at all.
  @default_kind Specs.ImplementV1.spec().kind

  @doc """
  The kind of a dispatch that names none: `implement@1`'s, because before `kind` existed the
  implement dispatch was the only one sent. `DispatchPayload.fill/3` defaults an absent `kind`
  to it, and `Spec.holds_claim?/1` reads a `nil` ledger kind as it.
  """
  @spec default_kind() :: String.t()
  def default_kind, do: @default_kind

  @claim_holding_kinds for spec <- @specs, Spec.holds_claim?(spec), do: spec.kind

  @doc """
  Every kind whose spec holds a claim (`Spec.holds_claim?/1`), in registry order: the same
  rule as a list, for a query filter on ledger rows (`DispatchLedger.where_holds_claim/1`).
  """
  @spec claim_holding_kinds() :: [String.t()]
  def claim_holding_kinds, do: @claim_holding_kinds
end
