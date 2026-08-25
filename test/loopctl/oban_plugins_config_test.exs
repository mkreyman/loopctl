defmodule Loopctl.ObanPluginsConfigTest do
  @moduledoc """
  US-34.1 (AC-34.1.4, TC-34.1.4): `Oban.Plugins.Reindexer` is configured, Lifeline is
  unchanged, and the Pruner keeps its seven-day `max_age` but now sets an explicit sweep
  `interval` instead of taking the library's 30-second default.

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

    test "Pruner keeps 7 days, and sweeps on an interval proportionate to that", %{
      plugins: plugins
    } do
      assert {Oban.Plugins.Pruner, opts} =
               Enum.find(plugins, &match?({Oban.Plugins.Pruner, _}, &1))

      assert opts[:max_age] == 60 * 60 * 24 * 7

      # The interval must be SET, because the library default is 30 seconds and nothing
      # about a seven-day retention wants a half-minute sweep. Measured on the hosted
      # database over the 19 days to 2026-08-25, the default cost 53,748 calls / 457s /
      # 12.1% of everything that database did, to delete ~5,600 rows a day.
      #
      # Asserted as a RANGE rather than an equality: the exact cadence is a tuning knob,
      # what must not regress is the ORDER of magnitude against max_age. Anything under a
      # minute is the pathology; anything over an hour delays reclaim enough to be a
      # deliberate decision rather than a tweak.
      assert is_integer(opts[:interval])
      assert opts[:interval] >= :timer.minutes(1)
      assert opts[:interval] <= :timer.hours(1)
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

  describe "DraftDuplicateSweepWorker crontab entry" do
    setup do
      plugins = Application.get_env(:loopctl, Oban)[:plugins]

      {Oban.Plugins.Cron, cron_opts} =
        Enum.find(plugins, &match?({Oban.Plugins.Cron, _}, &1))

      entry =
        Enum.find(cron_opts[:crontab], fn
          {_schedule, Loopctl.Workers.DraftDuplicateSweepWorker} -> true
          {_schedule, Loopctl.Workers.DraftDuplicateSweepWorker, _opts} -> true
          _ -> false
        end)

      %{entry: entry, crontab: cron_opts[:crontab]}
    end

    test "the DraftDuplicateSweepWorker entry exists in the crontab", %{entry: entry} do
      assert entry,
             "expected a DraftDuplicateSweepWorker crontab entry that drains the draft " <>
               "queue of published-duplicate holds"
    end

    test "it runs weekly and fans out across all tenants", %{entry: entry} do
      assert elem(entry, 0) == "50 5 * * 0"
      assert {_schedule, _worker, opts} = entry
      assert opts[:args] == %{"mode" => "all_tenants"}
    end

    test "it does not collide with the Sunday KnowledgeMoc fan-out", %{
      entry: entry,
      crontab: crontab
    } do
      # Both target the shared :knowledge lane on a Sunday. The sweep is deliberately
      # scheduled AFTER the MOC pass rather than at the same minute, so a wide MOC
      # fan-out is not competing with the sweep for the same queue slots.
      moc =
        Enum.find(crontab, fn tuple ->
          elem(tuple, 1) == Loopctl.Workers.KnowledgeMocWorker
        end)

      assert moc, "expected a KnowledgeMocWorker crontab entry to compare against"
      refute elem(entry, 0) == elem(moc, 0)
    end
  end

  describe "StructuralLinksWorker crontab entry" do
    setup do
      plugins = Application.get_env(:loopctl, Oban)[:plugins]

      {Oban.Plugins.Cron, cron_opts} =
        Enum.find(plugins, &match?({Oban.Plugins.Cron, _}, &1))

      entry =
        Enum.find(cron_opts[:crontab], fn
          {_schedule, Loopctl.Workers.StructuralLinksWorker} -> true
          {_schedule, Loopctl.Workers.StructuralLinksWorker, _opts} -> true
          _ -> false
        end)

      %{entry: entry, crontab: cron_opts[:crontab]}
    end

    test "the StructuralLinksWorker entry exists in the crontab", %{entry: entry} do
      assert entry,
             "expected a StructuralLinksWorker crontab entry — US-42.1 shipped harvest/2 " <>
               "with nothing running it on a cadence, and an unscheduled harvester leaves " <>
               "every source created after the one manual backfill without a hub"
    end

    test "it runs weekly and fans out across all tenants", %{entry: entry} do
      assert elem(entry, 0) == "0 6 * * 0"
      assert {_schedule, _worker, opts} = entry
      assert opts[:args] == %{"mode" => "all_tenants"}
    end

    test "it shares a minute with no other weekly :knowledge pass", %{
      entry: entry,
      crontab: crontab
    } do
      # KnowledgeMoc (05:00 Sun) and DraftDuplicateSweep (05:50 Sun) target the same
      # shared lane. Each of the three is scheduled at its own minute so a wide fan-out
      # is never competing with another fan-out for :knowledge queue slots.
      others =
        crontab
        |> Enum.filter(fn tuple ->
          elem(tuple, 1) in [
            Loopctl.Workers.KnowledgeMocWorker,
            Loopctl.Workers.DraftDuplicateSweepWorker
          ]
        end)
        |> Enum.map(&elem(&1, 0))

      assert length(others) == 2, "expected both weekly :knowledge fan-outs to compare against"
      refute elem(entry, 0) in others
    end
  end

  describe "#249: inert KB crons are PARKED by default" do
    setup do
      plugins = Application.get_env(:loopctl, Oban)[:plugins]

      {Oban.Plugins.Cron, cron_opts} =
        Enum.find(plugins, &match?({Oban.Plugins.Cron, _}, &1))

      %{workers: Enum.map(cron_opts[:crontab], &elem(&1, 1))}
    end

    test "no parked worker is scheduled with OBAN_UNPARK_CRONS unset", %{workers: workers} do
      still_scheduled = Enum.filter(Loopctl.ObanConfig.parked_crons(), &(&1 in workers))

      assert still_scheduled == [],
             "expected every parked worker to be absent from the crontab, but these are " <>
               "still scheduled: #{inspect(still_scheduled)}. Each was parked because it ran " <>
               "green while doing nothing (empty memory tier / frozen eval fixture / retired " <>
               "detector) — re-adding a schedule here silently restores that waste."
    end

    test "the parked set is exactly the five workers the audit found inert" do
      assert Enum.sort(Loopctl.ObanConfig.parked_crons()) ==
               Enum.sort([
                 Loopctl.Workers.MemoryPromotionSweepWorker,
                 Loopctl.Workers.MemoryGraduationSweepWorker,
                 Loopctl.Workers.SessionMemoryPruneWorker,
                 Loopctl.Workers.PromotionEvalWorker,
                 Loopctl.Workers.IngestionHealthWorker
               ])
    end

    test "unparked workers are non-empty when nothing is revived (the guard is real)" do
      # Mutation check: if reject_parked/2 stopped filtering, the assertion above would
      # pass vacuously only if parked_crons/0 were empty. Prove it is not.
      refute Loopctl.ObanConfig.parked_crons() == []
    end
  end

  describe "#249: OBAN_UNPARK_CRONS revives a parked cron" do
    # Parsing is exercised purely (never System.put_env) — that is VM-global and would
    # race the async suite.
    setup do
      full_crontab = [
        {"0 * * * *", Loopctl.Workers.MemoryGraduationSweepWorker},
        {"*/10 * * * *", Loopctl.Workers.MemoryPromotionSweepWorker},
        {"0 4 * * *", Loopctl.Workers.KnowledgeLintWorker, args: %{"mode" => "all_tenants"}}
      ]

      %{crontab: full_crontab}
    end

    test "reviving one worker restores ONLY that entry", %{crontab: crontab} do
      unparked = Loopctl.ObanConfig.parse_unparked("Loopctl.Workers.MemoryGraduationSweepWorker")

      workers =
        crontab
        |> Loopctl.ObanConfig.reject_parked(unparked)
        |> Enum.map(&elem(&1, 1))

      assert Loopctl.Workers.MemoryGraduationSweepWorker in workers
      refute Loopctl.Workers.MemoryPromotionSweepWorker in workers
      assert Loopctl.Workers.KnowledgeLintWorker in workers
    end

    test "its schedule is unchanged by parking — the hourly sweep (#411 Gap 3)", %{
      crontab: crontab
    } do
      unparked = Loopctl.ObanConfig.parse_unparked("Loopctl.Workers.MemoryGraduationSweepWorker")

      entry =
        crontab
        |> Loopctl.ObanConfig.reject_parked(unparked)
        |> Enum.find(&(elem(&1, 1) == Loopctl.Workers.MemoryGraduationSweepWorker))

      assert elem(entry, 0) == "0 * * * *"
    end

    test "the Elixir. prefixed form is accepted too" do
      assert Loopctl.ObanConfig.parse_unparked("Elixir.Loopctl.Workers.PromotionEvalWorker") ==
               [Loopctl.Workers.PromotionEvalWorker]
    end

    test "a nil / blank value revives nothing" do
      assert Loopctl.ObanConfig.parse_unparked(nil) == []
      assert Loopctl.ObanConfig.parse_unparked("  ,  ") == []
    end

    test "a typo RAISES rather than silently leaving the worker parked" do
      assert_raise ArgumentError, ~r/not a parked cron/, fn ->
        Loopctl.ObanConfig.parse_unparked("Loopctl.Workers.NoSuchWorker")
      end
    end

    test "a real but NON-parked worker also raises (cannot unpark what is not parked)" do
      assert_raise ArgumentError, ~r/not a parked cron/, fn ->
        Loopctl.ObanConfig.parse_unparked("Loopctl.Workers.KnowledgeLintWorker")
      end
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

  describe "US-40.B1: ChannelClaimSweeper crontab entry" do
    setup do
      plugins = Application.get_env(:loopctl, Oban)[:plugins]

      {Oban.Plugins.Cron, cron_opts} =
        Enum.find(plugins, &match?({Oban.Plugins.Cron, _}, &1))

      entry =
        Enum.find(cron_opts[:crontab], fn
          {_schedule, Loopctl.Workers.ChannelClaimSweeper} -> true
          {_schedule, Loopctl.Workers.ChannelClaimSweeper, _opts} -> true
          _ -> false
        end)

      %{entry: entry}
    end

    test "the ChannelClaimSweeper entry exists in the crontab", %{entry: entry} do
      assert entry,
             "expected a ChannelClaimSweeper crontab entry that lifecycle-sweeps spent " <>
               "channel_claims (US-40.B1)"
    end

    test "its schedule is the every-5-minutes sweep", %{entry: entry} do
      schedule = elem(entry, 0)
      assert schedule == "*/5 * * * *"
    end
  end

  describe "#499: ChannelPostRescanWorker crontab entry" do
    setup do
      plugins = Application.get_env(:loopctl, Oban)[:plugins]

      {Oban.Plugins.Cron, cron_opts} =
        Enum.find(plugins, &match?({Oban.Plugins.Cron, _}, &1))

      entry =
        Enum.find(cron_opts[:crontab], fn
          {_schedule, Loopctl.Workers.ChannelPostRescanWorker} -> true
          {_schedule, Loopctl.Workers.ChannelPostRescanWorker, _opts} -> true
          _ -> false
        end)

      %{entry: entry}
    end

    test "the ChannelPostRescanWorker entry exists in the crontab", %{entry: entry} do
      assert entry,
             "expected a ChannelPostRescanWorker crontab entry that retroactively rescans " <>
               "live channel_posts against the current secret denylist (#499)"
    end

    test "its schedule is the hourly rescan", %{entry: entry} do
      schedule = elem(entry, 0)
      assert schedule == "23 * * * *"
    end
  end

  describe "#551: LegacyEmbeddingRetirementWorker crontab entry" do
    setup do
      plugins = Application.get_env(:loopctl, Oban)[:plugins]

      {Oban.Plugins.Cron, cron_opts} =
        Enum.find(plugins, &match?({Oban.Plugins.Cron, _}, &1))

      entry =
        Enum.find(cron_opts[:crontab], fn
          {_schedule, Loopctl.Workers.LegacyEmbeddingRetirementWorker} -> true
          {_schedule, Loopctl.Workers.LegacyEmbeddingRetirementWorker, _opts} -> true
          _ -> false
        end)

      %{entry: entry}
    end

    test "the LegacyEmbeddingRetirementWorker entry exists in the crontab", %{entry: entry} do
      assert entry,
             "expected a LegacyEmbeddingRetirementWorker crontab entry — without a SCHEDULE " <>
               "the US-41.1 legacy-column retirement has no trigger at all, which is exactly " <>
               "the #551 defect"
    end

    test "its schedule is the daily off-peak observation", %{entry: entry} do
      schedule = elem(entry, 0)
      assert schedule == "40 3 * * *"
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
