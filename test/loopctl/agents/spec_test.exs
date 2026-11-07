defmodule Loopctl.Agents.SpecTest do
  @moduledoc """
  US-48.2: `Loopctl.Agents.Spec` refuses, AT COMPILE TIME, every field outside its closed set
  and every transition its archetype may not name (AC-48.2.1, AC-48.2.3).

  Each case compiles a real spec module through `Code.compile_string/1`, starting from
  `triage@1`'s or `implement@1`'s own fields so that exactly one thing is wrong, and asserts
  the `CompileError` names it. The first two cases prove the generator itself compiles a good
  spec, without which every refusal below would be vacuous.
  """

  use ExUnit.Case, async: true

  alias Loopctl.Agents.Spec
  alias Loopctl.Agents.Specs.ImplementV1
  alias Loopctl.Agents.Specs.TriageV1
  alias Loopctl.Delivery.StageMachine

  defp fields(spec_module), do: spec_module.spec() |> Map.from_struct() |> Enum.to_list()

  defp compile(fields) do
    name = "Loopctl.Agents.SpecTest.Generated#{System.unique_integer([:positive])}"

    source = """
    defmodule #{name} do
      use Loopctl.Agents.Spec, #{inspect(fields, limit: :infinity, printable_limit: :infinity)}
    end
    """

    [{module, _binary}] = Code.compile_string(source, "generated_spec.ex")
    module
  end

  defp refused(fields) do
    error = assert_raise CompileError, fn -> compile(fields) end
    Exception.message(error)
  end

  defp put(fields, key, value), do: Keyword.put(fields, key, value)

  describe "a valid spec" do
    test "triage@1's own fields compile to the same struct" do
      assert compile(fields(TriageV1)).spec() == TriageV1.spec()
    end

    test "implement@1's own fields compile to the same struct" do
      assert compile(fields(ImplementV1)).spec() == ImplementV1.spec()
    end
  end

  describe "the archetype edge rule (AC-48.2.3)" do
    # TC-48.2.3
    test "a :judge spec naming a runner-reportable transition fails to compile" do
      illegal = {:ci, :merged, :forward}
      assert StageMachine.runner_reportable?(:ci, :merged, :forward)

      message =
        TriageV1
        |> fields()
        |> put(:outcomes, %{"story" => [{:detected, :triaged, :forward}, illegal]})
        |> refused()

      assert message =~ inspect(illegal)
      assert message =~ "archetype :judge"
      assert message =~ "may name only control-only transitions"
    end

    test "a :draft spec naming a runner-reportable transition fails to compile" do
      illegal = {:ci, :implementing, :ci_red}

      message =
        TriageV1
        |> fields()
        |> put(:archetype, :draft)
        |> put(:effects, [])
        |> put(:outcomes, %{"draft" => [illegal]})
        |> refused()

      assert message =~ inspect(illegal)
      assert message =~ "archetype :draft"
    end

    test "a :build spec naming a control-only transition fails to compile" do
      illegal = {:triaged, :queued, :forward}
      refute StageMachine.runner_reportable?(:triaged, :queued, :forward)

      message =
        ImplementV1
        |> fields()
        |> put(:outcomes, %{"stage" => [illegal]})
        |> refused()

      assert message =~ inspect(illegal)
      assert message =~ "archetype :build"
      assert message =~ "may name only runner-reportable transitions"
    end

    # TC-48.2.4, for every archetype: the human edge is refused whatever the spec is.
    for archetype <- [:judge, :build, :draft] do
      test "a #{archetype} spec naming escalated -> queued over :human_resolution fails" do
        human = {:escalated, :queued, :human_resolution}
        assert StageMachine.human_only?(:human_resolution)

        base = if unquote(archetype) == :build, do: ImplementV1, else: TriageV1

        message =
          base
          |> fields()
          |> put(:archetype, unquote(archetype))
          |> put(:effects, [])
          |> put(:outcomes, %{"resolve" => [human]})
          |> refused()

        assert message =~ inspect(human)
        assert message =~ "human_only"
        assert message =~ "archetype #{inspect(unquote(archetype))}"
      end
    end

    test "the rule binds transitions named in screens and sweeps, not only outcomes" do
      illegal = {:pr_open, :ci, :forward}

      for field <- [:screens, :sweeps] do
        key = if field == :screens, do: :gate_a, else: :stranded_triaged_unbound

        message =
          TriageV1
          |> fields()
          |> put(field, %{key => [illegal]})
          |> refused()

        assert message =~ inspect(illegal), "#{field} was not checked"
        assert message =~ "archetype :judge"
      end
    end

    test "a transition the stage machine does not have is refused before the archetype rule" do
      bogus = {:detected, :done, :forward}
      refute bogus in StageMachine.transitions()

      message = TriageV1 |> fields() |> put(:outcomes, %{"story" => [bogus]}) |> refused()

      assert message =~ inspect(bogus)
      assert message =~ "not in StageMachine.transitions/0"
    end

    test "the archetype sets partition the machine: judge/draft, build and human-only" do
      transitions = StageMachine.transitions()
      control = Spec.allowed_transitions(:judge)
      build = Spec.allowed_transitions(:build)
      human = for {_f, _t, edge} = tr <- transitions, StageMachine.human_only?(edge), do: tr

      assert human != []
      assert Spec.allowed_transitions(:draft) == control
      assert build == StageMachine.runner_transitions()
      assert MapSet.disjoint?(MapSet.new(control), MapSet.new(build))
      assert MapSet.disjoint?(MapSet.new(control ++ build), MapSet.new(human))
      assert Enum.sort(control ++ build ++ human) == Enum.sort(Enum.uniq(transitions))
    end
  end

  describe "effects follow the archetype" do
    test "a :judge spec naming a runner-reportable effect fails to compile" do
      message = TriageV1 |> fields() |> put(:effects, [:head_sha]) |> refused()
      assert message =~ "[:head_sha]"
      assert message =~ "archetype :judge"
    end

    test "a :build spec naming the control-written triage binding fails to compile" do
      message = ImplementV1 |> fields() |> put(:effects, [:triage_dispatch_id]) |> refused()
      assert message =~ "[:triage_dispatch_id]"
      assert message =~ "archetype :build"
    end

    test "a :build spec may not name runner_id, which only the claim writes" do
      message = ImplementV1 |> fields() |> put(:effects, [:runner_id]) |> refused()
      assert message =~ "[:runner_id]"
    end
  end

  describe "closed-set fields (AC-48.2.1)" do
    @cases [
      {:archetype, :assess, "archetype :assess"},
      {:kind, "review", ~s(kind "review")},
      {:candidates,
       %{predicates: [{:stage, :detected}, :by_vibes], order: :round_robin_project_tenant},
       "[:by_vibes]"},
      {:candidates, %{predicates: [], order: :round_robin_project_tenant},
       "candidates.predicates must name at least one"},
      {:candidates, %{predicates: [{:stage, :detected}], order: :newest_first},
       "candidates.order :newest_first"},
      {:candidates, [{:stage, :detected}], "candidates must be"},
      {:candidates, %{predicates: [{:stage, :nowhere}], order: :round_robin_project_tenant},
       "{:stage, :nowhere}"},
      {:candidates,
       %{
         predicates: [{:stage, :detected}, :issue_not_closed],
         order: :round_robin_project_tenant
       }, ":issue_not_closed needs"},
      {:sweeps, %{forever: [{:detected, :triaged, :forward}]}, "[:forever]"},
      {:sweeps, [], "sweeps must be a map"},
      {:payload, :raw_reporter_text, "payload :raw_reporter_text"},
      {:refs, [branch: :source_base_branch], "refs must name exactly"},
      {:refs, [branch: :caller_supplied, base_branch: :source_base_branch], "refs [:branch]"},
      {:runner, [:connected, :friendly], "[:friendly]"},
      {:runner, [], "runner must name at least one"},
      {:runner, [:connected, :connected], "runner names a value twice"},
      {:budgets, {:triage_wall_clock_seconds, :dispatch_max_turns}, "budgets"},
      {:result, ["review_verdict"], ~s(["review_verdict"])},
      {:result, [], "result must name at least one"},
      {:screens, %{vibe_check: [{:triaged, :escalated, :triage_escalate}]}, "[:vibe_check]"},
      {:outcomes, %{}, "outcomes must be a non-empty map"},
      {:outcomes, %{story: [{:detected, :triaged, :forward}]}, "must be lower-case strings"},
      {:outcomes, %{"story" => []}, "must be a non-empty list of transitions"},
      {:effects, [:sends_email], "[:sends_email]"},
      {:rerun, :forever, "rerun :forever"},
      {:concurrency, :unbounded, "concurrency :unbounded"},
      {:prompt, "triage", "prompt"},
      {:prompt, {"triage", 0}, "prompt"},
      {:prompt, {"Triage Prompt", 1}, "prompt"},
      {:id, "Triage", "id"},
      {:version, 0, "version 0"}
    ]

    for {{field, value, expected}, index} <- Enum.with_index(@cases) do
      test "#{index}: #{field} = #{inspect(value)} fails to compile" do
        message =
          TriageV1 |> fields() |> put(unquote(field), unquote(Macro.escape(value))) |> refused()

        assert message =~ unquote(expected)
      end
    end

    # US-48.7. `advance_on` is a closed set of placement refusals, and only a spec that places
    # (`:build`) may name any.
    test "advance_on outside the closed set fails to compile" do
      message =
        ImplementV1 |> fields() |> put(:advance_on, [:runner_exhausted, :busy]) |> refused()

      assert message =~ "advance_on [:busy] not in [:runner_exhausted, :no_conforming_branch]"
    end

    test "advance_on naming a refusal twice fails to compile" do
      message =
        ImplementV1
        |> fields()
        |> put(:advance_on, [:runner_exhausted, :runner_exhausted])
        |> refused()

      assert message =~ "advance_on names a value twice"
    end

    test "a :judge spec naming any advance_on fails to compile" do
      message = TriageV1 |> fields() |> put(:advance_on, [:runner_exhausted]) |> refused()

      assert message =~
               "agent spec triage@1 (archetype :judge) names advance_on [:runner_exhausted]; " <>
                 "only a :build spec places"
    end

    test "an unknown field fails to compile" do
      message = TriageV1 |> fields() |> put(:owner_key, "lc_live_x") |> refused()
      assert message =~ "unknown field(s) [:owner_key]"
    end

    test "a missing field fails to compile" do
      message = TriageV1 |> fields() |> Keyword.delete(:screens) |> refused()
      assert message =~ "missing field(s) [:screens]"
    end

    test "a duplicated field fails to compile" do
      message = (fields(TriageV1) ++ [rerun: :next_pass]) |> refused()
      assert message =~ "duplicated field(s) [:rerun]"
    end
  end

  describe "named_transitions/1" do
    test "collects outcomes, screens and sweeps, once each" do
      named = Spec.named_transitions(TriageV1.spec())

      assert {:triaged, :queued, :forward} in named
      assert {:triaged, :failed, :triage_reject} in named
      assert {:triaged, :escalated, :triage_escalate} in named
      assert named == Enum.uniq(named)
    end
  end
end
