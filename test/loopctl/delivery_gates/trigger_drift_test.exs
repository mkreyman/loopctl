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
end
