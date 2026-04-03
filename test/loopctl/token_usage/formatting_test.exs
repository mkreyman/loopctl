defmodule Loopctl.TokenUsage.FormattingTest do
  use ExUnit.Case, async: true

  alias Loopctl.TokenUsage.Formatting

  describe "millicents_to_dollars/1" do
    test "converts 0 to 0.00" do
      assert Formatting.millicents_to_dollars(0) == "0.00"
    end

    test "converts 2500 millicents to 0.03" do
      # 2500 / 100_000 = 0.025 -> round half up -> 0.03
      assert Formatting.millicents_to_dollars(2500) == "0.03"
    end

    test "converts 100_000 millicents to 1.00" do
      assert Formatting.millicents_to_dollars(100_000) == "1.00"
    end

    test "converts 155 millicents to 0.00" do
      # 155 / 100_000 = 0.00155 -> rounds to 0.00
      assert Formatting.millicents_to_dollars(155) == "0.00"
    end

    test "converts 1_000_000 millicents to 10.00" do
      assert Formatting.millicents_to_dollars(1_000_000) == "10.00"
    end

    test "converts 50 millicents to 0.00" do
      assert Formatting.millicents_to_dollars(50) == "0.00"
    end

    test "converts 5000 millicents to 0.05" do
      assert Formatting.millicents_to_dollars(5000) == "0.05"
    end

    test "converts 250_000 to 2.50" do
      assert Formatting.millicents_to_dollars(250_000) == "2.50"
    end
  end

  describe "format_tokens/1" do
    test "formats values under 1000 as-is" do
      assert Formatting.format_tokens(0) == "0"
      assert Formatting.format_tokens(500) == "500"
      assert Formatting.format_tokens(999) == "999"
    end

    test "formats 1000 as 1K" do
      assert Formatting.format_tokens(1000) == "1K"
    end

    test "formats 1500 as 1.5K" do
      assert Formatting.format_tokens(1500) == "1.5K"
    end

    test "formats 10000 as 10K" do
      assert Formatting.format_tokens(10_000) == "10K"
    end

    test "formats 999_000 as 999K" do
      assert Formatting.format_tokens(999_000) == "999K"
    end

    test "formats 1_000_000 as 1M" do
      assert Formatting.format_tokens(1_000_000) == "1M"
    end

    test "formats 1_500_000 as 1.5M" do
      assert Formatting.format_tokens(1_500_000) == "1.5M"
    end

    test "formats 2_500_000 as 2.5M" do
      assert Formatting.format_tokens(2_500_000) == "2.5M"
    end

    test "formats 10_000_000 as 10M" do
      assert Formatting.format_tokens(10_000_000) == "10M"
    end
  end
end
