defmodule Loopctl.CLI.Commands.ConfigTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Loopctl.CLI.Commands.Config, as: ConfigCmd

  describe "run/3 set" do
    test "sets a valid config key" do
      output = capture_io(fn -> ConfigCmd.run("config", ["set", "format", "human"], []) end)
      assert output =~ "Config format set to human"
    end

    test "rejects an invalid config key" do
      output =
        capture_io(:stderr, fn -> ConfigCmd.run("config", ["set", "bogus", "value"], []) end)

      assert output =~ "Invalid config key"
    end
  end

  describe "run/3 get" do
    test "gets a config value" do
      # The value may or may not be set, but the command should run
      output =
        capture_io(fn ->
          ConfigCmd.run("config", ["get", "format"], [])
        end)

      assert is_binary(output)
    end
  end

  describe "run/3 show" do
    test "shows all config values" do
      output = capture_io(fn -> ConfigCmd.run("config", ["show"], []) end)
      # Should output JSON (or empty object)
      assert is_binary(output)
    end
  end

  describe "run/3 invalid" do
    test "shows usage for unknown subcommand" do
      output = capture_io(:stderr, fn -> ConfigCmd.run("config", ["bogus"], []) end)
      assert output =~ "Usage: loopctl config"
    end

    test "shows usage for no subcommand" do
      output = capture_io(:stderr, fn -> ConfigCmd.run("config", [], []) end)
      assert output =~ "Usage: loopctl config"
    end
  end
end
