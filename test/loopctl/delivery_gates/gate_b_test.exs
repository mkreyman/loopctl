defmodule Loopctl.DeliveryGates.GateBTest do
  use ExUnit.Case, async: true

  import Loopctl.Fixtures

  alias Loopctl.DeliveryGates
  alias Loopctl.DeliveryGates.GateB
  alias Loopctl.DeliveryGates.GateB.Result
  alias Loopctl.DeliveryGates.Glob
  alias Loopctl.DeliveryGates.RepoTriggers
  alias Loopctl.DeliveryGates.Triggers

  @repo "acme/claims-app"

  defp sha256(binary), do: :sha256 |> :crypto.hash(binary) |> Base.encode16(case: :lower)

  defp triggers(config \\ build(:delivery_gates_config)) do
    binary = Jason.encode!(config)
    Triggers.parse(binary, sha256(binary))
  end

  defp input(attrs \\ %{}), do: build(:gate_b_input, attrs)

  defp evaluate(phase, attrs \\ %{}, triggers \\ triggers()) do
    GateB.evaluate(phase, input(attrs), triggers)
  end

  describe ":clear" do
    test "an unguarded change within limits, in both phases" do
      for phase <- [:triage, :merge] do
        assert %Result{phase: ^phase, outcome: :clear, reasons: [], effect_matches: []} =
                 evaluate(phase)
      end
    end

    test "through the facade" do
      assert %Result{outcome: :clear} = DeliveryGates.gate_b(:merge, input(), triggers())
    end
  end

  describe "only the merge run is a merge precondition" do
    test "triage results never are, whatever their outcome" do
      refute evaluate(:triage).merge_precondition?
      refute evaluate(:triage, %{files: ["lib/app_web/router.ex"]}).merge_precondition?
    end

    test "merge results always are" do
      assert evaluate(:merge).merge_precondition?
      assert evaluate(:merge, %{files: ["lib/app_web/router.ex"]}).merge_precondition?
    end
  end

  describe ":prove_effect" do
    test "each effect path, in both phases" do
      for {file, pattern} <- [
            {"priv/rates/2026.csv", "priv/rates/**"},
            {"lib/app/payments/submit.ex", "lib/app/payments/**"},
            {"config/runtime.exs", "config/runtime.exs"}
          ],
          phase <- [:triage, :merge] do
        assert %Result{outcome: :prove_effect, reasons: [], effect_matches: [{^file, ^pattern}]} =
                 evaluate(phase, %{files: ["lib/app/accounts/user.ex", file]})
      end
    end

    test "a one-line data edit with no code touched" do
      result =
        evaluate(:merge, %{
          files: ["priv/rates/2026.csv"],
          diffstat: %{files: 1, changed_lines: 2}
        })

      assert result.outcome == :prove_effect
    end

    test "a new file under an effect path that is not yet in the repository" do
      assert %Result{outcome: :prove_effect} =
               evaluate(:triage, %{files: ["lib/app/payments/refund.ex"]})
    end
  end

  describe ":human" do
    test "each human path, in both phases" do
      for {file, pattern} <- [
            {"lib/app_web/router.ex", "lib/app_web/router.ex"},
            {"lib/app/data_migrations/backfill_rates.ex", "lib/**/data_migrations/**"},
            {"lib/data_migrations/new_one.ex", "lib/**/data_migrations/**"}
          ],
          phase <- [:triage, :merge] do
        assert %Result{outcome: :human, reasons: [{:human_path, ^file, ^pattern}]} =
                 evaluate(phase, %{files: [file]})
      end
    end

    test "beats :prove_effect, and still records the effect matches" do
      result = evaluate(:merge, %{files: ["priv/rates/2026.csv", "lib/app_web/router.ex"]})

      assert result.outcome == :human
      assert result.reasons == [{:human_path, "lib/app_web/router.ex", "lib/app_web/router.ex"}]
      assert result.effect_matches == [{"priv/rates/2026.csv", "priv/rates/**"}]
    end

    test "a path that is not one git would print" do
      for bad <- [
            "/lib/app.ex",
            "./lib/app.ex",
            "lib/../lib/app_web/router.ex",
            "lib//x.ex",
            "",
            nil
          ] do
        result = evaluate(:triage, %{files: [bad]})
        assert result.outcome == :human
        assert {:invalid_path, bad} in result.reasons
      end
    end

    test "no files, or files that are not a list" do
      assert %Result{outcome: :human, reasons: [:no_files]} = evaluate(:triage, %{files: []})

      assert %Result{outcome: :human, reasons: [:missing_files]} =
               GateB.evaluate(:triage, Map.delete(input(), :files), triggers())

      assert %Result{outcome: :human, reasons: [:missing_files]} =
               evaluate(:merge, %{files: "lib/app.ex"})
    end

    test "an input that is not a map, or a phase that is not :triage or :merge" do
      assert %Result{outcome: :human, reasons: [:invalid_input]} =
               GateB.evaluate(:merge, [files: []], triggers())

      assert %Result{
               outcome: :human,
               reasons: [{:invalid_phase, :deploy}],
               merge_precondition?: false
             } =
               evaluate(:deploy)
    end
  end

  describe "size limits apply at :merge only" do
    test "exactly at the limits is within them" do
      files = for n <- 1..12, do: "lib/app/accounts/f#{n}.ex"

      assert %Result{outcome: :clear} =
               evaluate(:merge, %{files: files, diffstat: %{files: 12, changed_lines: 1000}})
    end

    test "one file over max_files" do
      files = for n <- 1..13, do: "lib/app/accounts/f#{n}.ex"

      assert %Result{outcome: :human, reasons: [{:max_files_exceeded, 13, 12}]} =
               evaluate(:merge, %{files: files, diffstat: %{files: 13, changed_lines: 10}})
    end

    test "a diffstat file count over the limit, even if the name list is short" do
      assert %Result{outcome: :human, reasons: [{:max_files_exceeded, 40, 12}]} =
               evaluate(:merge, %{diffstat: %{files: 40, changed_lines: 10}})
    end

    test "a name list over the limit, even if the diffstat undercounts" do
      files = for n <- 1..13, do: "lib/app/accounts/f#{n}.ex"

      assert %Result{outcome: :human, reasons: [{:max_files_exceeded, 13, 12}]} =
               evaluate(:merge, %{files: files, diffstat: %{files: 1, changed_lines: 10}})
    end

    test "one line over max_changed_lines" do
      assert %Result{outcome: :human, reasons: [{:max_changed_lines_exceeded, 1001, 1000}]} =
               evaluate(:merge, %{diffstat: %{files: 1, changed_lines: 1001}})
    end

    test "the size limits beat :prove_effect" do
      assert %Result{outcome: :human} =
               evaluate(:merge, %{
                 files: ["priv/rates/2026.csv"],
                 diffstat: %{files: 1, changed_lines: 5000}
               })
    end

    test "are not applied at :triage" do
      files = for n <- 1..40, do: "lib/app/accounts/f#{n}.ex"

      assert %Result{outcome: :clear} =
               evaluate(:triage, %{files: files, diffstat: %{files: 40, changed_lines: 99_999}})
    end

    test "a missing diffstat at :merge escalates; at :triage it is not needed" do
      assert %Result{outcome: :human, reasons: [:missing_diffstat]} =
               GateB.evaluate(:merge, Map.delete(input(), :diffstat), triggers())

      assert %Result{outcome: :clear} =
               GateB.evaluate(:triage, Map.delete(input(), :diffstat), triggers())
    end

    test "a malformed diffstat at :merge escalates" do
      for bad <- [
            %{files: 1},
            %{files: -1, changed_lines: 1},
            %{files: 1, changed_lines: "10"},
            7
          ] do
        assert %Result{outcome: :human, reasons: [{:invalid_diffstat, ^bad}]} =
                 evaluate(:merge, %{diffstat: bad})
      end
    end
  end

  describe "fails closed on configuration" do
    test "no configuration loaded" do
      assert %Result{outcome: :human, reasons: [{:config_error, :not_loaded}]} =
               evaluate(:merge, %{}, nil)
    end

    test "every parse error, passed through untouched" do
      binary = Jason.encode!(build(:delivery_gates_config))

      for parsed <- [
            Triggers.parse(nil, sha256(binary)),
            Triggers.parse(binary, String.duplicate("0", 64)),
            Triggers.parse("{", sha256("{")),
            triggers(build(:delivery_gates_config, %{"version" => 99}))
          ] do
        assert {:error, reason} = parsed

        assert %Result{outcome: :human, reasons: [{:config_error, ^reason}]} =
                 evaluate(:merge, %{}, parsed)
      end
    end

    test "a value that is not a parse result, including a bare struct" do
      {:ok, parsed} = triggers()

      for other <- [parsed, :ok, {:ok, %{}}, %{}] do
        assert %Result{outcome: :human, reasons: [{:config_error, :unrecognised}]} =
                 evaluate(:merge, %{}, other)
      end
    end

    test "a hand-built trigger set with an empty pattern list is never read as no triggers" do
      {:ok, glob} = Glob.compile("lib/app_web/router.ex")

      for repo_triggers <- [
            %RepoTriggers{
              effect_paths: [],
              human_paths: [glob],
              max_files: 12,
              max_changed_lines: 1000
            },
            %RepoTriggers{
              effect_paths: [glob],
              human_paths: [],
              max_files: 12,
              max_changed_lines: 1000
            },
            %RepoTriggers{
              effect_paths: [glob],
              human_paths: [glob],
              max_files: 0,
              max_changed_lines: 1000
            },
            %RepoTriggers{
              effect_paths: [glob],
              human_paths: [glob],
              max_files: 12,
              max_changed_lines: nil
            }
          ] do
        forged = {:ok, %Triggers{version: 1, sha256: "", repos: %{@repo => repo_triggers}}}

        assert %Result{outcome: :human, reasons: [{:config_error, :empty_trigger_set}]} =
                 evaluate(:merge, %{}, forged)
      end
    end

    test "an unknown repository" do
      assert %Result{outcome: :human, reasons: [{:unknown_repo, "acme/other"}]} =
               evaluate(:merge, %{repo: "acme/other"})

      assert %Result{outcome: :human, reasons: [{:unknown_repo, nil}]} =
               GateB.evaluate(:merge, Map.delete(input(), :repo), triggers())
    end
  end

  describe "stale triggers" do
    test "a configured pattern that matches no file in the repository escalates, naming it" do
      repo_files = input().repo_files -- ["lib/app_web/router.ex"]

      assert %Result{outcome: :human, reasons: [{:stale_trigger, "lib/app_web/router.ex"}]} =
               evaluate(:triage, %{repo_files: repo_files})
    end

    test "a renamed effect directory escalates even when the change touches nothing" do
      repo_files =
        Enum.map(input().repo_files, &String.replace(&1, "priv/rates/", "priv/fee_rates/"))

      assert %Result{outcome: :human, reasons: [{:stale_trigger, "priv/rates/**"}]} =
               evaluate(:merge, %{repo_files: repo_files})
    end

    test "missing, empty, or malformed repo_files escalates" do
      assert %Result{outcome: :human, reasons: [:missing_repo_files]} =
               GateB.evaluate(:merge, Map.delete(input(), :repo_files), triggers())

      assert %Result{outcome: :human, reasons: [:missing_repo_files]} =
               evaluate(:merge, %{repo_files: []})

      assert %Result{outcome: :human, reasons: [:invalid_repo_files]} =
               evaluate(:merge, %{repo_files: ["README.md", nil]})
    end
  end

  describe "agents may only add an escalation" do
    test "an agent escalation turns a :clear change into :human" do
      assert %Result{outcome: :human, reasons: [{:agent_escalation, "suspects rate change"}]} =
               evaluate(:triage, %{agent_escalations: ["suspects rate change"]})
    end

    test "every element counts as an escalation, including ones that read as negatives" do
      for negative <- [false, nil, "no escalation needed", %{"escalate" => false}] do
        assert %Result{outcome: :human, reasons: [{:agent_escalation, ^negative}]} =
                 evaluate(:merge, %{agent_escalations: [negative]})
      end
    end

    test "an empty or absent agent list, or an agent's all-clear, cannot clear a computed trigger" do
      computed = [
        {%{files: ["lib/app_web/router.ex"]}, :human},
        {%{files: ["priv/rates/2026.csv"]}, :prove_effect},
        {%{diffstat: %{files: 1, changed_lines: 5000}}, :human}
      ]

      agent_all_clear = [
        %{agent_escalations: []},
        %{agent_escalations: nil},
        %{agent_escalations: [], agent_verdict: "no escalation needed", escalate: false},
        %{agent_escalations: [], override: :clear, suppress: [:human_path]}
      ]

      for {change, expected} <- computed, all_clear <- agent_all_clear do
        assert %Result{outcome: ^expected} = evaluate(:merge, Map.merge(change, all_clear))
      end
    end

    test "agent escalations are added even when the configuration failed" do
      result = evaluate(:merge, %{agent_escalations: ["x"]}, nil)
      assert result.reasons == [{:config_error, :not_loaded}, {:agent_escalation, "x"}]
    end

    test "agent escalations that are not a list escalate rather than being ignored" do
      for bad <- [false, "none", %{}] do
        assert %Result{outcome: :human, reasons: [{:invalid_agent_escalations, ^bad}]} =
                 evaluate(:merge, %{agent_escalations: bad})
      end
    end
  end
end
