defmodule Loopctl.ObanPluginsConfigTest do
  @moduledoc """
  US-34.1 (AC-34.1.4, TC-34.1.4): `Oban.Plugins.Reindexer` is configured, and the
  pre-existing Lifeline/Pruner plugins are unchanged.

  Pure config read — no DB, no running Oban needed (`config/test.exs` sets
  `testing: :inline`, under which plugins are not started, but the KEYWORD LIST
  configured in `config/config.exs` still merges into `Application.get_env/2`).
  """
  use ExUnit.Case, async: true

  describe "Oban plugins config" do
    setup do
      plugins = Application.get_env(:loopctl, Oban)[:plugins]
      %{plugins: plugins}
    end

    test "Oban.Plugins.Reindexer is configured (AC-34.1.4)", %{plugins: plugins} do
      assert Enum.any?(plugins, &reindexer?/1),
             "expected Oban.Plugins.Reindexer in the plugins list, got: #{inspect(plugins)}"
    end

    test "Lifeline is unchanged (rescue_after: 30 min)", %{plugins: plugins} do
      assert {Oban.Plugins.Lifeline, opts} =
               Enum.find(plugins, &match?({Oban.Plugins.Lifeline, _}, &1))

      assert opts[:rescue_after] == :timer.minutes(30)
    end

    test "Pruner is unchanged (max_age: 7 days)", %{plugins: plugins} do
      assert {Oban.Plugins.Pruner, opts} =
               Enum.find(plugins, &match?({Oban.Plugins.Pruner, _}, &1))

      assert opts[:max_age] == 60 * 60 * 24 * 7
    end

    test "Cron is still present (unchanged by this story)", %{plugins: plugins} do
      assert Enum.any?(plugins, &match?({Oban.Plugins.Cron, _}, &1))
    end
  end

  defp reindexer?(Oban.Plugins.Reindexer), do: true
  defp reindexer?({Oban.Plugins.Reindexer, _opts}), do: true
  defp reindexer?(_other), do: false
end
