defmodule Loopctl.DeliveryGates.Measurement.GateBReplayTest do
  use ExUnit.Case, async: true

  import Loopctl.Fixtures

  alias Loopctl.DeliveryGates.Measurement.GateBReplay
  alias Loopctl.DeliveryGates.Triggers

  @repo "acme/claims-app"

  # No tenant: the harness is pure and takes no tenant_id, so there is nothing to isolate.

  defp triggers(overrides \\ %{}) do
    document = :delivery_gates_config |> build(overrides) |> Jason.encode!()
    Triggers.parse(document, :sha256 |> :crypto.hash(document) |> Base.encode16(case: :lower))
  end

  defp replay(change_attrs, triggers \\ nil) do
    GateBReplay.replay(build(:measurement_change, change_attrs), @repo, triggers || triggers())
  end

  describe "outcomes — one per trigger class" do
    test "a change touching nothing guarded is :clear" do
      assert %{outcome: :clear, reasons: [], effect_matches: []} =
               replay(files: ["lib/app/accounts/user.ex"])
    end

    test "an EFFECT path is :prove_effect and names the pattern that matched" do
      result = replay(files: ["priv/rates/2026.csv"])

      assert result.outcome == :prove_effect
      assert result.reasons == []
      assert "priv/rates/**" in result.effect_matches
    end

    test "a HUMAN path is :human" do
      result = replay(files: ["lib/app_web/router.ex"])

      assert result.outcome == :human
      assert Enum.any?(result.reasons, &match?({:human_path, "lib/app_web/router.ex", _}, &1))
    end

    test "a human path BEATS an effect path in the same change" do
      result = replay(files: ["priv/rates/2026.csv", "lib/app_web/router.ex"])

      assert result.outcome == :human
    end

    test "a glob human path matches through a wildcard segment" do
      assert %{outcome: :human} = replay(files: ["lib/app/data_migrations/backfill_rates.ex"])
    end
  end

  describe "the size bound" do
    test "over max_files is :size_bound, not :human" do
      files = for n <- 1..13, do: "lib/app/accounts/user_#{n}.ex"

      result =
        replay(files: files, diffstat: %{files: 13, changed_lines: 10})

      assert result.outcome == :size_bound
      assert Enum.any?(result.reasons, &match?({:max_files_exceeded, 13, 12}, &1))
      assert Enum.any?(result.reasons, &match?({:hard_bound_files_exceeded, 13, 12}, &1))
    end

    test "exactly at the bound is not over it" do
      files = for n <- 1..12, do: "lib/app/accounts/user_#{n}.ex"

      assert %{outcome: :clear} =
               replay(files: files, diffstat: %{files: 12, changed_lines: 1000})
    end

    test "over max_changed_lines is :size_bound" do
      result = replay(diffstat: %{files: 1, changed_lines: 1001})

      assert result.outcome == :size_bound
      assert Enum.any?(result.reasons, &match?({:max_changed_lines_exceeded, 1001, 1000}, &1))
    end

    test "a change that is BOTH over the bound and on a human path is :human" do
      # The path is the stronger statement: the gate found something, rather than declining to
      # look. Classifying it as :size_bound would hide a human-path hit inside the size bucket.
      result =
        replay(
          files: ["lib/app_web/router.ex"],
          diffstat: %{files: 40, changed_lines: 9_000}
        )

      assert result.outcome == :human
    end

    test "the design's ceiling holds even when the configuration raises max_files" do
      loose =
        triggers(%{
          "repos" => %{
            @repo => %{
              "effect_paths" => ["priv/rates/**"],
              "human_paths" => ["lib/app_web/router.ex"],
              "limits" => %{"max_files" => 500, "max_changed_lines" => 100_000}
            }
          }
        })

      files = for n <- 1..13, do: "lib/app/accounts/user_#{n}.ex"

      result =
        GateBReplay.replay(
          build(:measurement_change,
            files: files,
            diffstat: %{files: 13, changed_lines: 10},
            head_files: ["priv/rates/2026.csv", "lib/app_web/router.ex" | files],
            base_files: ["priv/rates/2026.csv", "lib/app_web/router.ex" | files]
          ),
          @repo,
          loose
        )

      assert result.outcome == :size_bound
      assert Enum.any?(result.reasons, &match?({:hard_bound_files_exceeded, 13, 12}, &1))
      refute Enum.any?(result.reasons, &match?({:max_files_exceeded, _, _}, &1))
    end
  end

  describe "refuses rather than guesses" do
    test "a diff that does not parse is :human, naming the reason" do
      result = replay(diff: "M" <> <<0>> <> "lib/app/accounts/user.ex")

      assert result.outcome == :human
      assert Enum.any?(result.reasons, &match?({:unreadable_diff, :unterminated}, &1))
    end

    test "a change with NO files is :human, never cleared" do
      result = replay(diff: "", diffstat: %{files: 0, changed_lines: 0})

      assert result.outcome == :human
      assert :no_files in result.reasons
    end

    test "a trigger configuration that did not parse escalates every change" do
      assert %{outcome: :human, reasons: [{:config_error, :missing_config}]} =
               replay([files: ["lib/app/accounts/user.ex"]], Triggers.parse(nil, nil))
    end

    test "an unknown repository escalates" do
      result =
        GateBReplay.replay(build(:measurement_change, []), "someone/else", triggers())

      assert result.outcome == :human
      assert Enum.any?(result.reasons, &match?({:unknown_repo, "someone/else"}, &1))
    end

    test "a pattern matching nothing in the tree is a stale trigger, recorded as such" do
      result =
        replay(
          head_files: ["lib/app/accounts/user.ex"],
          base_files: ["lib/app/accounts/user.ex"]
        )

      assert result.outcome == :human
      assert "priv/rates/**" in result.stale_triggers
    end

    test "unreadable/2 keeps a change nobody could read in the corpus" do
      result = GateBReplay.unreadable("deadbeef", :root_commit)

      assert result.outcome == :unreadable
      assert result.error == :root_commit
      refute GateBReplay.scored?(result)
    end
  end

  describe "false_negative?/1" do
    test "a cleared change the oracle calls effect-bearing IS one" do
      result = replay(files: ["lib/app/accounts/user.ex"], content: ~s|@code "T1019"|)

      assert result.outcome == :clear
      assert GateBReplay.false_negative?(result)
    end

    test "a cleared change the oracle calls inert is NOT one" do
      result = replay(files: ["lib/app/accounts/user.ex"], content: "def render(assigns) do")

      assert result.outcome == :clear
      refute GateBReplay.false_negative?(result)
    end

    test "an ESCALATED change the oracle calls effect-bearing is not a false negative" do
      # The gate stopped it. A false negative is only ever something the gate let through.
      result = replay(files: ["lib/app_web/router.ex"], content: ~s|@code "T1019"|)

      assert result.outcome == :human
      refute GateBReplay.false_negative?(result)
    end

    test "a clear whose oracle could not run is unscored, neither true nor false" do
      result = replay(files: ["lib/app/accounts/user.ex"], content: nil)

      assert result.outcome == :clear
      assert result.oracle == nil
      refute GateBReplay.false_negative?(result)
      refute GateBReplay.scored?(result)
    end
  end

  describe "production_files?" do
    test "a change only under test/ and docs/ is not production" do
      refute replay(files: ["test/app/user_test.exs", "docs/design.md"]).production_files?
    end

    test "one production file among test files is production" do
      assert replay(files: ["test/app/user_test.exs", "lib/app/accounts/user.ex"]).production_files?
    end
  end
end
