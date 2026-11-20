defmodule LoopctlRunner.HeadlessFixtureTest do
  @moduledoc """
  The suite's CI launcher (`test/support/headless/claude-headless.sh`) is claude-config's
  `bin/claude-headless.sh`, byte for byte. CI runs the suite through the copy because the CI
  account has no claude-config; on a fleet machine this test reads both and fails on any
  difference, so the copy can never test a launcher the fleet does not run.
  """
  use ExUnit.Case, async: true

  alias LoopctlRunner.TestSupport

  @tag skip:
         not File.exists?(TestSupport.fleet_headless_launcher()) &&
           "claude-config is not on this machine"
  test "the CI fixture is claude-config's launcher, byte for byte" do
    assert File.read!(TestSupport.fixture_headless_launcher()) ==
             File.read!(TestSupport.fleet_headless_launcher()),
           "claude-config's claude-headless.sh changed: copy it over " <>
             "runner/test/support/headless/claude-headless.sh"
  end

  test "the fixture is executable and the launcher selection is explicit" do
    assert Bitwise.band(File.stat!(TestSupport.fixture_headless_launcher()).mode, 0o111) != 0

    assert TestSupport.headless_launcher(%{"LOOPCTL_RUNNER_HEADLESS" => "fixture"}) ==
             TestSupport.fixture_headless_launcher()

    assert TestSupport.headless_launcher(%{}) == TestSupport.fleet_headless_launcher()
  end
end
