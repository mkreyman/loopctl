defmodule Loopctl.Delivery.RetryCeilingTest do
  @moduledoc """
  US-44.4: the retry ceiling's reader, parser and decision. Pure — no database, no tenant — so
  there is no tenant-isolation case here; the ceiling's effect on a tenant's rows is asserted
  where it is applied, in `Loopctl.Delivery.StagesTest`.
  """

  use ExUnit.Case, async: true

  alias Loopctl.Delivery.RetryCeiling

  describe "max_attempts/1 — the reader every release calls" do
    # TC-44.4.4 (AC-44.4.5): the ceiling is spend, so it has NO default. A config with no key
    # reads as 0, and one counted release against 0 escalates.
    test "a config with no max-attempts key is a ceiling of 0, and one counted release escalates" do
      ceiling = RetryCeiling.max_attempts([])

      assert ceiling == 0
      assert RetryCeiling.decide(1, ceiling) == {:escalate, :attempts_exhausted}
    end

    test "a configured value is read as it is" do
      assert RetryCeiling.max_attempts(dispatch_max_attempts: 3) == 3
      assert RetryCeiling.max_attempts(dispatch_max_attempts: 0) == 0
    end

    test "a value that is not a non-negative integer reads as 0, never a guess" do
      assert RetryCeiling.max_attempts(dispatch_max_attempts: -1) == 0
      assert RetryCeiling.max_attempts(dispatch_max_attempts: "3") == 0
      assert RetryCeiling.max_attempts(dispatch_max_attempts: nil) == 0
    end

    test "with no argument it reads the application env, which config/test.exs sets to 2" do
      assert RetryCeiling.max_attempts() == 2
    end
  end

  describe "parse/1 — what config/runtime.exs reads DISPATCH_MAX_ATTEMPTS through" do
    test "a non-negative integer is taken" do
      assert RetryCeiling.parse("2") == {:ok, 2}
      assert RetryCeiling.parse(" 5 ") == {:ok, 5}
      assert RetryCeiling.parse("0") == {:ok, 0}
    end

    test "unset, blank, negative or malformed is :unset" do
      for value <- [nil, "", "  ", "-1", "two", "2.5", "3x"] do
        assert RetryCeiling.parse(value) == :unset, inspect(value)
      end
    end
  end

  describe "decide/2" do
    test "fewer counted releases than the ceiling retry; reaching it escalates" do
      assert RetryCeiling.decide(1, 2) == :retry
      assert RetryCeiling.decide(2, 2) == {:escalate, :attempts_exhausted}
      assert RetryCeiling.decide(3, 2) == {:escalate, :attempts_exhausted}
    end
  end

  describe "counted_releases/1" do
    test "sums runner_lost and claim_released, and nothing else" do
      attempts = %{
        "runner_lost" => 2,
        "claim_released" => 1,
        "ci_red" => 7,
        "operator_released" => 4,
        "attempts_exhausted" => 1
      }

      assert RetryCeiling.counted_releases(attempts) == 3
    end

    test "a row with neither key has spent nothing" do
      assert RetryCeiling.counted_releases(%{}) == 0
      assert RetryCeiling.counted_releases(%{"review_findings" => 2}) == 0
    end
  end

  describe "config/runtime.exs — DISPATCH_MAX_ATTEMPTS reaches the reader" do
    # The WIRING: `runtime.exs` parses the variable into the key `max_attempts/0` reads. Run in a
    # `mix run --no-start` subprocess with the variable set ONLY there (never `System.put_env`,
    # which is VM-global and would race every async test), the way `Loopctl.ObanConfigTest`
    # exercises its own env-driven boot path.
    @tag :tmp_dir
    test "a set value is what every release reads", %{tmp_dir: tmp_dir} do
      assert read_ceiling(tmp_dir, "5") == 5
    end

    @tag :tmp_dir
    test "a malformed value is not a ceiling: the key keeps the value config/test.exs set",
         %{tmp_dir: tmp_dir} do
      assert read_ceiling(tmp_dir, "lots") == 2
    end
  end

  test "the exhausted reason names the count and the ceiling" do
    reason = RetryCeiling.exhausted_reason(2, 2)

    assert reason =~ "attempts_exhausted: 2 counted releases"
    assert reason =~ "retry ceiling of 2"
    assert reason =~ "DISPATCH_MAX_ATTEMPTS"
  end

  defp read_ceiling(tmp_dir, value) do
    result_path = Path.join(tmp_dir, "ceiling.bin")

    script =
      "File.write!(#{inspect(result_path)}, " <>
        ":erlang.term_to_binary(Loopctl.Delivery.RetryCeiling.max_attempts()))"

    {output, exit_code} =
      System.cmd("mix", ["run", "--no-start", "-e", script],
        env: [{"MIX_ENV", "test"}, {"DISPATCH_MAX_ATTEMPTS", value}],
        stderr_to_stdout: true
      )

    assert exit_code == 0, "subprocess failed (exit #{exit_code}):\n#{output}"

    result_path |> File.read!() |> :erlang.binary_to_term()
  end
end
