defmodule Loopctl.ObanPluginsConfigTest do
  @moduledoc """
  US-34.1 (AC-34.1.4, TC-34.1.4): `Oban.Plugins.Reindexer` is configured, and the
  pre-existing Lifeline/Pruner plugins are unchanged.

  Pure config read — no DB, no running Oban needed (`config/test.exs` sets
  `testing: :inline`, under which plugins are not started). As of US-35.3 the
  `:plugins` list is owned exclusively by `Loopctl.ObanConfig.plugins/0` and set at
  RUNTIME in `config/runtime.exs` (`config :loopctl, Oban, plugins:
  Loopctl.ObanConfig.plugins()`); `config/config.exs` no longer sets `plugins:`.
  `runtime.exs` runs in every environment (test included), so the crontab / Lifeline /
  Pruner / Reindexer this module asserts on are read straight from that runtime-set
  value via `Application.get_env/2`.
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

  describe "US-35.3: all-tenants ComputeSthWorker safety-sweep cron (AC-35.3.1, TC-35.3.1)" do
    setup do
      plugins = Application.get_env(:loopctl, Oban)[:plugins]

      {Oban.Plugins.Cron, cron_opts} =
        Enum.find(plugins, &match?({Oban.Plugins.Cron, _}, &1))

      entry =
        Enum.find(cron_opts[:crontab], fn
          {_schedule, Loopctl.Workers.ComputeSthWorker, opts} ->
            Keyword.get(opts, :args) == %{"mode" => "all_tenants"}

          _ ->
            false
        end)

      %{entry: entry}
    end

    test "the all_tenants ComputeSthWorker entry exists in the crontab", %{entry: entry} do
      assert entry, "expected an all_tenants ComputeSthWorker crontab entry"
    end

    test "its schedule is no longer the per-minute poll", %{entry: entry} do
      {schedule, _worker, _opts} = entry
      refute schedule == "* * * * *"
    end

    test "its schedule is config-driven (equals ObanConfig.sth_sweep_cron/0)", %{entry: entry} do
      {schedule, _worker, _opts} = entry
      assert schedule == Loopctl.ObanConfig.sth_sweep_cron()
    end
  end

  describe "US-38.2: RateLimitCounterCleanupWorker crontab entry" do
    setup do
      plugins = Application.get_env(:loopctl, Oban)[:plugins]

      {Oban.Plugins.Cron, cron_opts} =
        Enum.find(plugins, &match?({Oban.Plugins.Cron, _}, &1))

      entry =
        Enum.find(cron_opts[:crontab], fn
          {_schedule, Loopctl.Workers.RateLimitCounterCleanupWorker} -> true
          {_schedule, Loopctl.Workers.RateLimitCounterCleanupWorker, _opts} -> true
          _ -> false
        end)

      %{entry: entry}
    end

    test "the RateLimitCounterCleanupWorker entry exists in the crontab", %{entry: entry} do
      assert entry,
             "expected a RateLimitCounterCleanupWorker crontab entry that prunes expired " <>
               "rate_limit_counters windows (US-38.2)"
    end

    test "its schedule is the every-10-minutes prune", %{entry: entry} do
      schedule = elem(entry, 0)
      assert schedule == "*/10 * * * *"
    end
  end

  describe "#411 Gap 3: MemoryGraduationSweepWorker crontab entry" do
    setup do
      plugins = Application.get_env(:loopctl, Oban)[:plugins]

      {Oban.Plugins.Cron, cron_opts} =
        Enum.find(plugins, &match?({Oban.Plugins.Cron, _}, &1))

      entry =
        Enum.find(cron_opts[:crontab], fn
          {_schedule, Loopctl.Workers.MemoryGraduationSweepWorker} -> true
          {_schedule, Loopctl.Workers.MemoryGraduationSweepWorker, _opts} -> true
          _ -> false
        end)

      %{entry: entry}
    end

    test "the MemoryGraduationSweepWorker entry exists in the crontab", %{entry: entry} do
      assert entry,
             "expected a MemoryGraduationSweepWorker crontab entry that graduates hot " <>
               "memories into durable knowledge articles (#411 Gap 3)"
    end

    test "its schedule is the hourly sweep (slower than the 10-min promotion sweep)", %{
      entry: entry
    } do
      schedule = elem(entry, 0)
      assert schedule == "0 * * * *"
    end
  end

  describe "US-39.5: ChannelPostSweeper crontab entry" do
    setup do
      plugins = Application.get_env(:loopctl, Oban)[:plugins]

      {Oban.Plugins.Cron, cron_opts} =
        Enum.find(plugins, &match?({Oban.Plugins.Cron, _}, &1))

      entry =
        Enum.find(cron_opts[:crontab], fn
          {_schedule, Loopctl.Workers.ChannelPostSweeper} -> true
          {_schedule, Loopctl.Workers.ChannelPostSweeper, _opts} -> true
          _ -> false
        end)

      %{entry: entry}
    end

    test "the ChannelPostSweeper entry exists in the crontab", %{entry: entry} do
      assert entry,
             "expected a ChannelPostSweeper crontab entry that TTL-sweeps expired " <>
               "channel_posts (US-39.5)"
    end

    test "its schedule is the every-5-minutes sweep", %{entry: entry} do
      schedule = elem(entry, 0)
      assert schedule == "*/5 * * * *"
    end
  end

  describe "US-35.3: sth_sweep_cron/0 (config-based DI, runtime-tunable)" do
    test "defaults to a 5-minute sweep when STH_SWEEP_CRON is unset" do
      # STH_SWEEP_CRON is not set in the test environment, so the default applies.
      assert Loopctl.ObanConfig.sth_sweep_cron() == "*/5 * * * *"
    end
  end

  defp reindexer?(Oban.Plugins.Reindexer), do: true
  defp reindexer?({Oban.Plugins.Reindexer, _opts}), do: true
  defp reindexer?(_other), do: false
end
