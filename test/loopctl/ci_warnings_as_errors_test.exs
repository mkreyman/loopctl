defmodule Loopctl.CiWarningsAsErrorsTest do
  @moduledoc """
  `mix test` runs with `--warnings-as-errors` in the `test` CI job and in `mix precommit`.
  This guard fails the build if either drops it.

  ## What it is for, which is not "tidy warnings"

  Two test files declaring ONE module name have two outcomes under Elixir's parallel
  compiler, and which one you get is a race over whether the two are in flight at once:

  - both at once — `cannot define module X because it is currently being defined`, a hard
    `CompileError`. Deterministic when those are the only two files loaded (measured 8/8,
    and still 8/8 under `ELIXIR_ERL_OPTIONS="+S 1"`, so it is not scheduler count).
  - one finishing first — `warning: redefining module X (current version defined in
    memory)`, and the suite passes having loaded only ONE of the two files' tests.

  #824 shipped the second kind: `test/loopctl_web/fallback_controller_test.exs` duplicated
  `LoopctlWeb.FallbackControllerTest`, CI reported `9936 tests, 0 failures`, and the same
  tree could not compile its test suite locally. **The failure mode is not a red build. It
  is a green suite that ran less than it claimed and said nothing.** `--warnings-as-errors`
  is what turns that warning into an exit 1.

  ## Why it is affordable, and what would overturn it

  Measured when it was added: zero load-time warnings, both on a warm tree and after
  `mix compile --force` in `MIX_ENV=test`. If a future dependency bump floods the suite
  with warnings nobody can fix that day, this becomes a blocker — the answer then is to fix
  them or to change this test DELIBERATELY, in the same commit, with the reason. It is not
  to quietly drop the flag from one of the two sites and leave the other asserting it.

  ## Scope, stated so it is not mistaken for coverage it does not have

  The flag is asserted on the two `mix test` steps of the `test` job (the one the `gate`
  required check hangs on) and on the `precommit` alias. It is deliberately NOT asserted on
  the scale / scale-nightly / pgbouncer jobs: those run tagged subsets on the self-hosted
  runner and their load-time warning count has never been measured, so requiring it there
  would be an unmeasured claim. A duplicate module name still reaches them; the two gates
  above are what stop it reaching master.

  Same class of guard as `Loopctl.CiScaleNightlyCronTest` — a decision a later reader could
  undo as one line of YAML nobody diffs.
  """

  use ExUnit.Case, async: true

  @ci ".github/workflows/ci.yml"
  @flag "--warnings-as-errors"

  test "the test job's `mix test` step carries --warnings-as-errors" do
    assert step_command("Run tests") == "mix test #{@flag}",
           """
           The `Run tests` step in #{@ci} no longer runs with #{@flag}:

               #{inspect(step_command("Run tests"))}

           Without it a duplicate test-module name can pass CI green while only one of the
           two files' tests ran — which is exactly what happened on 2d476a2 (#824).
           """
  end

  test "the e2e step carries it too — it loads the same suite" do
    assert step_command("Run e2e journey tests") == "mix test --only e2e #{@flag}",
           """
           The `Run e2e journey tests` step in #{@ci} no longer runs with #{@flag}:

               #{inspect(step_command("Run e2e journey tests"))}

           It requires the whole test suite to load, so it sees the same redefinition
           warning the default run does.
           """
  end

  test "`mix precommit` runs the suite with it, so the commit hook catches it first" do
    precommit = Mix.Project.config()[:aliases][:precommit]

    test_step = Enum.find(precommit, &(is_binary(&1) and String.starts_with?(&1, "test")))

    assert test_step == "test #{@flag}",
           """
           The `precommit` alias's test step is #{inspect(test_step)}, not "test #{@flag}".

           The local copy is the one that matters: the pre-commit hook runs this alias, so
           with the flag a duplicate module name never reaches CI at all.
           """
  end

  # The step's `run:` value, from the workflow YAML. Read as text rather than through a YAML
  # parser for the same reason `Loopctl.CiScaleNightlyCronTest` does: the assertion is about
  # the literal line a human diffs.
  defp step_command(step_name) do
    ~r/^\s*- name: #{Regex.escape(step_name)}\n\s*run: (.+)$/m
    |> Regex.run(File.read!(@ci), capture: :all_but_first)
    |> case do
      [command] -> String.trim(command)
      nil -> nil
    end
  end
end
