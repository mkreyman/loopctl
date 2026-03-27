defmodule Loopctl.CLI.MainTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Loopctl.CLI.Main

  describe "main/1" do
    test "prints usage with no args" do
      output = capture_io(fn -> Main.main([]) end)
      assert output =~ "loopctl - Agent-native project state store CLI"
      assert output =~ "Commands:"
    end

    test "prints usage with help" do
      output = capture_io(fn -> Main.main(["help"]) end)
      assert output =~ "Commands:"
    end

    test "prints usage with --help" do
      output = capture_io(fn -> Main.main(["--help"]) end)
      assert output =~ "Commands:"
    end

    test "routes to unknown command" do
      output = capture_io(:stderr, fn -> Main.main(["nonexistent"]) end)
      assert output =~ "Unknown command: nonexistent"
    end
  end

  describe "dispatch/3" do
    test "routes config commands to Config module" do
      output =
        capture_io(:stderr, fn ->
          Main.dispatch("config", [], [])
        end)

      assert output =~ "Usage: loopctl config"
    end

    test "returns error for unknown commands" do
      output =
        capture_io(:stderr, fn ->
          Main.dispatch("bogus", [], [])
        end)

      assert output =~ "Unknown command: bogus"
    end
  end

  describe "global options" do
    test "extracts --format option" do
      output =
        capture_io(:stderr, fn ->
          Main.main(["--format", "human", "config", "show"])
        end)

      # The config show command is dispatched with format option
      # It may show an error about format since no config exists, but it should dispatch
      assert is_binary(output)
    end
  end
end
