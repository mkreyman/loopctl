defmodule Loopctl.ObanPluginsTest do
  @moduledoc """
  US-34.1 (AC-34.1.4, TC-34.1.4): `Oban.Plugins.Reindexer` is configured (periodic
  `REINDEX CONCURRENTLY` on the `oban_jobs` args/meta indexes), and this change left
  `Oban.Plugins.Lifeline` and `Oban.Plugins.Pruner` unchanged. Pure config read — no
  DB needed, so this is plain `ExUnit.Case` (mirrors `Loopctl.ObanConfigTest`).
  """
  use ExUnit.Case, async: true

  describe "Oban plugins (compile-time config)" do
    test "Oban.Plugins.Reindexer is configured" do
      plugins = Application.get_env(:loopctl, Oban)[:plugins]

      assert Enum.any?(plugins, fn
               Oban.Plugins.Reindexer -> true
               {Oban.Plugins.Reindexer, _opts} -> true
               _ -> false
             end)
    end

    test "Oban.Plugins.Lifeline is unchanged (rescue_after: 30 minutes)" do
      plugins = Application.get_env(:loopctl, Oban)[:plugins]

      assert {Oban.Plugins.Lifeline, opts} =
               Enum.find(plugins, &match?({Oban.Plugins.Lifeline, _}, &1))

      assert Keyword.get(opts, :rescue_after) == :timer.minutes(30)
    end

    test "Oban.Plugins.Pruner is unchanged (max_age: 7 days)" do
      plugins = Application.get_env(:loopctl, Oban)[:plugins]

      assert {Oban.Plugins.Pruner, opts} =
               Enum.find(plugins, &match?({Oban.Plugins.Pruner, _}, &1))

      assert Keyword.get(opts, :max_age) == 60 * 60 * 24 * 7
    end

    test "Oban.Plugins.Cron is unchanged (still configured)" do
      plugins = Application.get_env(:loopctl, Oban)[:plugins]

      assert Enum.any?(plugins, &match?({Oban.Plugins.Cron, _}, &1))
    end

    test "Oban.Stager is NOT listed in plugins (it is a core GenServer, not a plugin, in Oban 2.21)" do
      plugins = Application.get_env(:loopctl, Oban)[:plugins]

      refute Enum.any?(plugins, fn
               Oban.Stager -> true
               {Oban.Stager, _opts} -> true
               _ -> false
             end)
    end
  end
end
