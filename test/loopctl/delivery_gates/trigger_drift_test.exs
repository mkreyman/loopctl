defmodule Loopctl.DeliveryGates.TriggerDriftTest do
  use ExUnit.Case, async: true

  alias Loopctl.DeliveryGates.GateB
  alias Loopctl.DeliveryGates.Glob
  alias Loopctl.DeliveryGates.RepoTriggers
  alias Loopctl.DeliveryGates.TriggerDrift
  alias Loopctl.DeliveryGates.Triggers

  # Pure over structs and path lists. No tenant appears anywhere in this module — the drift
  # check reads no database and takes no tenant_id — so there is nothing for a tenant-isolation
  # case to isolate.

  defp globs(patterns),
    do:
      Enum.map(patterns, fn p ->
        {:ok, g} = Glob.compile(p)
        g
      end)

  defp triggers(effect, human) do
    %RepoTriggers{
      effect_paths: globs(effect),
      human_paths: globs(human),
      max_files: 12,
      max_changed_lines: 1000
    }
  end

  describe "unmatched/2" do
    test "is empty when every pattern matches at least one file" do
      triggers = triggers(["priv/rates/**", "config/runtime.exs"], ["lib/app_web/router.ex"])

      files = ["priv/rates/a.csv", "config/runtime.exs", "lib/app_web/router.ex", "mix.exs"]

      assert TriggerDrift.unmatched(triggers, files) == {:ok, []}
    end

    test "names every pattern that matches nothing, in configuration order" do
      triggers =
        triggers(
          ["priv/rates/**", "lib/app/gone/**", "config/runtime.exs"],
          ["lib/app_web/router.ex", "lib/app_web/moved.ex"]
        )

      files = ["priv/rates/a.csv", "config/runtime.exs", "lib/app_web/router.ex"]

      assert TriggerDrift.unmatched(triggers, files) ==
               {:ok, ["lib/app/gone/**", "lib/app_web/moved.ex"]}
    end

    test "a rename is what drift looks like: the pattern survives, the file it named does not" do
      triggers = triggers(["lib/app/payments/**"], ["lib/app_web/router.ex"])

      assert TriggerDrift.unmatched(triggers, [
               "lib/app/payments/charge.ex",
               "lib/app_web/router.ex"
             ]) ==
               {:ok, []}

      # The directory was renamed. Nothing about the configuration changed; the guard is gone.
      assert TriggerDrift.unmatched(triggers, [
               "lib/app/billing/charge.ex",
               "lib/app_web/router.ex"
             ]) ==
               {:ok, ["lib/app/payments/**"]}
    end
  end

  describe "fail closed" do
    test "an empty file list is a refusal, never a clean tree" do
      triggers = triggers(["priv/rates/**"], ["lib/app_web/router.ex"])

      assert TriggerDrift.unmatched(triggers, []) == {:error, :missing_repo_files}
      assert TriggerDrift.coverage(triggers, []) == {:error, :missing_repo_files}
    end

    test "an absent or non-list file list is a refusal" do
      triggers = triggers(["priv/rates/**"], ["lib/app_web/router.ex"])

      assert TriggerDrift.unmatched(triggers, nil) == {:error, :missing_repo_files}
      assert TriggerDrift.unmatched(triggers, "priv/rates/a.csv") == {:error, :missing_repo_files}
    end

    test "a file list carrying a non-binary is a refusal" do
      triggers = triggers(["priv/rates/**"], ["lib/app_web/router.ex"])

      assert TriggerDrift.unmatched(triggers, ["priv/rates/a.csv", :atom]) ==
               {:error, :invalid_repo_files}
    end
  end

  describe "coverage/2" do
    test "counts matches per pattern, tagged by kind and configuration index" do
      triggers = triggers(["priv/rates/**", "lib/app/gone/**"], ["lib/app_web/router.ex"])

      files = ["priv/rates/a.csv", "priv/rates/b.csv", "lib/app_web/router.ex"]

      assert TriggerDrift.coverage(triggers, files) ==
               {:ok,
                [
                  %{kind: :effect, index: 0, pattern: "priv/rates/**", matches: 2},
                  %{kind: :effect, index: 1, pattern: "lib/app/gone/**", matches: 0},
                  %{kind: :human, index: 0, pattern: "lib/app_web/router.ex", matches: 1}
                ]}
    end
  end

  describe "the gate and the checker are one implementation" do
    test "Gate B's stale-trigger reasons are exactly the checker's unmatched patterns" do
      config = %{
        "version" => 1,
        "repos" => %{
          "acme/app" => %{
            "effect_paths" => ["priv/rates/**", "lib/app/gone/**"],
            "human_paths" => ["lib/app_web/router.ex"],
            "limits" => %{"max_files" => 12, "max_changed_lines" => 1000}
          }
        }
      }

      binary = Jason.encode!(config)
      sha = :sha256 |> :crypto.hash(binary) |> Base.encode16(case: :lower)
      {:ok, parsed} = Triggers.parse(binary, sha)
      {:ok, repo_triggers} = Triggers.fetch_repo(parsed, "acme/app")

      repo_files = ["priv/rates/a.csv", "lib/app_web/router.ex", "mix.exs"]

      result =
        GateB.evaluate(
          :merge,
          %{
            repo: "acme/app",
            files: ["mix.exs"],
            renames: [],
            repo_files: repo_files,
            diffstat: %{files: 1, changed_lines: 1}
          },
          {:ok, parsed}
        )

      {:ok, unmatched} = TriggerDrift.unmatched(repo_triggers, repo_files)

      assert unmatched == ["lib/app/gone/**"]
      assert result.outcome == :human

      assert Enum.filter(result.reasons, &match?({:stale_trigger, _}, &1)) == [
               {:stale_trigger, "lib/app/gone/**"}
             ]
    end

    test "Gate B still escalates on an unreadable file list rather than clearing" do
      config = %{
        "version" => 1,
        "repos" => %{
          "acme/app" => %{
            "effect_paths" => ["priv/rates/**"],
            "human_paths" => ["lib/app_web/router.ex"],
            "limits" => %{"max_files" => 12, "max_changed_lines" => 1000}
          }
        }
      }

      binary = Jason.encode!(config)
      sha = :sha256 |> :crypto.hash(binary) |> Base.encode16(case: :lower)
      parsed = Triggers.parse(binary, sha)

      for {repo_files, reason} <- [{[], :missing_repo_files}, {[:atom], :invalid_repo_files}] do
        result =
          GateB.evaluate(
            :merge,
            %{
              repo: "acme/app",
              files: ["mix.exs"],
              renames: [],
              repo_files: repo_files,
              diffstat: %{files: 1, changed_lines: 1}
            },
            parsed
          )

        assert result.outcome == :human
        assert reason in result.reasons
      end
    end
  end

  describe "agree?/2 — the two matchers cannot silently diverge" do
    # unmatched/2 short-circuits and coverage/2 counts. They share Glob.match?/2 and the
    # fail-closed guard and nothing else, so nothing but this makes them answer the same
    # question. A disagreement is the failure the moduledoc calls worse than no checker: the
    # artifact attests every guard alive while the gate escalates on a stale trigger.
    test "they agree when nothing has drifted" do
      triggers = triggers(["priv/rates/**", "config/runtime.exs"], ["lib/app_web/router.ex"])

      assert TriggerDrift.agree?(triggers, [
               "priv/rates/a.csv",
               "config/runtime.exs",
               "lib/app_web/router.ex"
             ])
    end

    test "they agree on which patterns drifted, not merely on how many" do
      triggers =
        triggers(
          ["priv/rates/**", "lib/app/gone/**", "config/runtime.exs"],
          ["lib/app_web/router.ex", "lib/app_web/moved.ex"]
        )

      files = ["priv/rates/a.csv", "config/runtime.exs", "lib/app_web/router.ex"]

      assert TriggerDrift.agree?(triggers, files)

      {:ok, unmatched} = TriggerDrift.unmatched(triggers, files)
      {:ok, coverage} = TriggerDrift.coverage(triggers, files)

      assert Enum.sort(unmatched) ==
               coverage
               |> Enum.filter(&(&1.matches == 0))
               |> Enum.map(& &1.pattern)
               |> Enum.sort()
    end

    test "they agree on every refusal, not only on the happy path" do
      triggers = triggers(["priv/rates/**"], ["lib/app_web/router.ex"])

      for repo_files <- [[], nil, "not-a-list", ["priv/rates/a.csv", :atom]] do
        assert TriggerDrift.agree?(triggers, repo_files),
               "the two matchers disagree on #{inspect(repo_files)}"
      end
    end

    test "agreed?/2 SEES a disagreement — the only way to prove the checker can fail" do
      # The two matchers agree on every real input, so feeding agree?/2 real inputs can never
      # show that its comparison works. These pairs are constructed to disagree.
      refute TriggerDrift.agreed?(
               {:ok, ["lib/app/gone/**"]},
               {:ok, [%{kind: :effect, index: 0, pattern: "lib/app/gone/**", matches: 3}]}
             )

      refute TriggerDrift.agreed?(
               {:ok, []},
               {:ok, [%{kind: :effect, index: 0, pattern: "lib/app/gone/**", matches: 0}]}
             )

      refute TriggerDrift.agreed?(
               {:ok, ["a/**"]},
               {:ok, [%{kind: :effect, index: 0, pattern: "b/**", matches: 0}]}
             )

      refute TriggerDrift.agreed?({:ok, []}, {:error, :missing_repo_files})
      refute TriggerDrift.agreed?({:error, :missing_repo_files}, {:ok, []})
      refute TriggerDrift.agreed?({:error, :missing_repo_files}, {:error, :invalid_repo_files})

      # And says so when they do agree, or the refutes above prove only that it always fails.
      assert TriggerDrift.agreed?(
               {:ok, ["lib/app/gone/**"]},
               {:ok, [%{kind: :effect, index: 0, pattern: "lib/app/gone/**", matches: 0}]}
             )

      assert TriggerDrift.agreed?({:error, :missing_repo_files}, {:error, :missing_repo_files})
    end

    test "a pattern matching exactly one file is where a short-circuit and a count could part" do
      triggers = triggers(["priv/rates/only.csv", "priv/rates/**"], ["lib/app_web/router.ex"])

      assert TriggerDrift.agree?(triggers, ["priv/rates/only.csv", "lib/app_web/router.ex"])
    end
  end

  describe "describe_error/1 — a parse failure is reported without its pattern" do
    test "an invalid pattern is reduced to its kind and the key path's depth" do
      reason =
        {:invalid_pattern, ["repos", "acme/private-repo", "effect_paths"], "priv/secret/**"}

      described = TriggerDrift.describe_error(reason)

      assert described == "invalid_pattern (key path depth 3)"
      refute described =~ "priv/secret"
      refute described =~ "acme/private-repo"
    end

    test "a bare atom reason survives as itself" do
      assert TriggerDrift.describe_error(:checksum_mismatch) ==
               "checksum_mismatch (key path depth 0)"
    end

    test "an unrecognised reason shape still says nothing about its contents" do
      described = TriggerDrift.describe_error(%{pattern: "priv/secret/**"})

      assert described == "unknown (key path depth 0)"
      refute described =~ "priv/secret"
    end
  end
end
