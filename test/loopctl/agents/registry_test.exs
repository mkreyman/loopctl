defmodule Loopctl.Agents.RegistryTest do
  @moduledoc """
  US-48.2: the agent-spec registry agrees with every list it must agree with (AC-48.2.2,
  AC-48.2.4), and nothing outside `lib/loopctl/agents/` reads it yet (AC-48.2.2, AC-48.2.5).

  Each binding reads the REAL value — the contract's kinds, the database's CHECK, the triage
  route table, the budget-key reader, the stage machine — rather than a copied literal, so a
  change on either side goes red here.

  No tenant isolation case, deliberately: the registry holds no tenant data, and AC-48.2.5's
  point is that it never will — the last describe block pins that.
  """

  use Loopctl.DataCase, async: true

  alias Loopctl.Agents.Registry
  alias Loopctl.Agents.Spec
  alias Loopctl.Agents.Specs.ImplementV1
  alias Loopctl.Agents.Specs.TriageV1
  alias Loopctl.ApiSpec.RunnerContract
  alias Loopctl.ApiSpec.RunnerContract.Kinds
  alias Loopctl.Delivery.DispatchPayload
  alias Loopctl.Delivery.StageMachine
  alias Loopctl.Delivery.TriageVerdict

  describe "lookup" do
    test "holds triage@1 as a :judge and implement@1 as a :build" do
      assert {:ok, %Spec{archetype: :judge, kind: "triage"} = triage} =
               Registry.fetch("triage", 1)

      assert {:ok, %Spec{archetype: :build, kind: "implement"} = implement} =
               Registry.fetch("implement", 1)

      assert triage == TriageV1.spec()
      assert implement == ImplementV1.spec()
      assert Registry.all() == [triage, implement]
    end

    test "for_kind/1 finds each kind's spec and refuses an unknown one" do
      assert {:ok, %Spec{id: "triage"}} = Registry.for_kind("triage")
      assert {:ok, %Spec{id: "implement"}} = Registry.for_kind("implement")
      assert Registry.for_kind("review") == {:error, :unknown_kind}
    end

    test "fetch/2 refuses an unknown id or version" do
      assert Registry.fetch("triage", 2) == {:error, :unknown_spec}
      assert Registry.fetch("reply_draft", 1) == {:error, :unknown_spec}
    end
  end

  describe "kinds (TC-48.2.1)" do
    test "registry kinds == RunnerContract.Kinds.all/0 == the runner_dispatches_kind CHECK" do
      [[definition]] =
        Repo.query!(
          "SELECT pg_get_constraintdef(oid) FROM pg_constraint " <>
            "WHERE conname = 'runner_dispatches_kind'"
        ).rows

      in_check =
        ~r/'([a-z_]+)'/
        |> Regex.scan(definition, capture: :all_but_first)
        |> List.flatten()
        |> Enum.sort()

      assert in_check != []
      assert Registry.kinds() == Enum.sort(Kinds.all())
      assert Registry.kinds() == in_check
    end

    test "every spec's kind is dispatchable" do
      for spec <- Registry.all(), do: assert(spec.kind in Kinds.dispatchable())
    end
  end

  describe "triage@1 outcomes (TC-48.2.2)" do
    test "the verdict outcomes are exactly TriageVerdict's and the contract's enum" do
      verdict_outcomes = TriageV1.spec().outcomes |> Map.delete("incomplete") |> Map.keys()

      assert Enum.sort(verdict_outcomes) == TriageVerdict.outcomes()
      assert Enum.sort(verdict_outcomes) == Enum.sort(Map.keys(TriageVerdict.routes()))

      assert Enum.sort(verdict_outcomes) ==
               Enum.sort(RunnerContract.RunnerTriageVerdict.outcomes())
    end

    test "each outcome's route is TriageVerdict's: the triage step, then its @routes entry" do
      outcomes = TriageV1.spec().outcomes

      for {outcome, leave} <- TriageVerdict.routes() do
        assert {:ok, route} = TriageVerdict.transitions_for(outcome)
        assert outcomes[outcome] == route, "#{outcome} disagrees with TriageVerdict"
        assert tl(outcomes[outcome]) == leave
      end
    end

    test "incomplete routes exactly as escalate does" do
      incomplete = TriageV1.spec().outcomes["incomplete"]

      assert incomplete == TriageVerdict.incomplete_transitions()
      assert {:ok, ^incomplete} = TriageVerdict.transitions_for("escalate")
    end

    test "every verdict screen escalates over the same edge escalate takes" do
      {:ok, [_triaged, escalate]} = TriageVerdict.transitions_for("escalate")
      screens = TriageV1.spec().screens

      for screen <- [:gate_a, :gate_b, :draft_injection, :draft_dispatchable] do
        assert screens[screen] == [escalate], "#{screen}"
      end

      assert screens[:payload_too_large] == TriageVerdict.incomplete_transitions()
      assert TriageV1.spec().sweeps[:stranded_triaged_unbound] == screens[:payload_too_large]
    end
  end

  describe "implement@1 outcomes" do
    test "a stage report may carry exactly the runner-reportable transitions" do
      assert Enum.sort(ImplementV1.spec().outcomes["stage"]) ==
               Enum.sort(StageMachine.runner_transitions())
    end

    test "its effects are exactly the runner-reportable effects" do
      assert Enum.sort(ImplementV1.spec().effects) == Enum.sort(StageMachine.reportable_effects())
    end

    test "triage@1's only stage-machine effect is the control-written triage binding" do
      stage_effects = TriageV1.spec().effects -- [:story_draft]

      assert stage_effects == [:triage_dispatch_id]
      assert :triage_dispatch_id in StageMachine.control_written_effects()
    end
  end

  describe "shared bindings (AC-48.2.4)" do
    test "budget keys == DispatchPayload.budget_keys/1 for every spec" do
      for spec <- Registry.all() do
        assert spec.budgets == DispatchPayload.budget_keys(spec.kind), spec.id
      end
    end

    test "every named transition is in StageMachine.transitions/0" do
      named = Enum.flat_map(Registry.all(), &Spec.named_transitions/1)

      assert named != []
      for transition <- named, do: assert(transition in StageMachine.transitions())
    end

    test "no spec names a human-only edge" do
      for spec <- Registry.all(), {_from, _to, edge} <- Spec.named_transitions(spec) do
        refute StageMachine.human_only?(edge), spec.id
      end
    end

    test "refs name exactly the contract's ref fields" do
      ref_fields = RunnerContract.RunnerDispatch.ref_fields() |> Keyword.keys() |> Enum.sort()

      for spec <- Registry.all() do
        assert spec.refs |> Keyword.keys() |> Enum.sort() == ref_fields, spec.id
      end
    end

    test "every result message is one the runner channel accepts" do
      for spec <- Registry.all(), message <- spec.result do
        assert message in RunnerContract.inbound_events(), "#{spec.id}: #{message}"
      end
    end
  end

  describe "read only where a story moved it, stored nowhere (AC-48.2.2, AC-48.2.5, US-48.3)" do
    # The modules a story has moved onto the registry, each with its equivalence test. A new
    # reader belongs to the story that moves it, and is added here by that story.
    @readers [
      # US-48.3: the candidate builder and the two `candidates/1` that delegate to it.
      "lib/loopctl/agents/candidates.ex",
      "lib/loopctl/delivery/dispatch_driver.ex",
      "lib/loopctl/delivery/triage_dispatcher.ex",
      # US-48.4: the `:judge` pass, and the cron caller that runs it with `triage@1`.
      "lib/loopctl/agents/dispatcher.ex",
      "lib/loopctl/workers/triage_dispatch_worker.ex"
    ]

    test "only the modules a story moved onto the registry name it or a spec" do
      reference = ~r/Agents\.(Registry|Specs?)\b|Agents\.\{/
      sources = Path.wildcard("lib/**/*.ex")

      own =
        Path.wildcard("lib/loopctl/agents/{spec,registry}.ex") ++
          Path.wildcard("lib/loopctl/agents/specs/*.ex")

      # Non-vacuous: the pattern matches the registry's own files, and the scan sees lib/web.
      assert length(own) == 4
      assert Enum.all?(own, &(&1 |> File.read!() |> String.match?(reference)))
      assert Enum.any?(sources, &String.starts_with?(&1, "lib/loopctl_web/"))

      readers =
        for path <- sources -- own,
            path |> File.read!() |> String.match?(reference),
            do: path

      # Both directions: no unlisted reader, and no listed one that has stopped reading.
      assert Enum.sort(readers) == Enum.sort(@readers)
    end

    test "no migration creates storage for specs" do
      migrations = Path.wildcard("priv/repo/migrations/*.exs")

      assert migrations != []

      assert Enum.filter(migrations, &(&1 |> File.read!() |> String.contains?("agent_spec"))) ==
               []
    end
  end
end
