defmodule Loopctl.FlyTomlTest do
  @moduledoc """
  Issue #815: `fly.toml` must stop the VM with SIGTERM, and give the graceful stop that
  SIGTERM runs enough time to finish. Fly's default is SIGINT, which drops the BEAM into its
  break handler: no application stop, no socket drain, and the runner sockets vanish with
  nothing logged.

  The timeout is checked against the ACTUAL shutdown budget: every endpoint socket's drainer
  `shutdown` (read from `LoopctlWeb.Endpoint.__sockets__/0`, and required to be set
  explicitly), plus Bandit's connection drain and Oban's grace period.
  """

  use ExUnit.Case, async: true

  alias Loopctl.Delivery.DispatchDriver
  alias Loopctl.Runners.Capacity

  # Defaults of the dependencies whose own shutdown follows the socket drain, used unless
  # config sets them: ThousandIsland's `shutdown_timeout` and Oban's `shutdown_grace_period`.
  @bandit_shutdown_ms 15_000
  @oban_grace_ms 15_000

  defp top_level(path) do
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.take_while(&(not String.starts_with?(String.trim_leading(&1), "[")))
    |> Enum.flat_map(fn line ->
      case Regex.run(~r/^\s*([a-z_]+)\s*=\s*(.+?)\s*(#.*)?$/, line) do
        [_, key, value | _] -> [{key, value}]
        _ -> []
      end
    end)
    |> Map.new()
  end

  test "fly.toml stops the VM with SIGTERM, not Fly's default SIGINT" do
    assert top_level("fly.toml")["kill_signal"] == ~s("SIGTERM")
  end

  test "kill_timeout outlasts the socket drain, Bandit's drain and Oban's grace, together" do
    kill_timeout_ms = String.to_integer(top_level("fly.toml")["kill_timeout"]) * 1_000

    drains =
      for {_path, socket, opts} <- LoopctlWeb.Endpoint.__sockets__() do
        drainer = Keyword.get(opts, :drainer)
        assert is_list(drainer), "#{inspect(socket)} has no explicit drainer configuration"
        Keyword.fetch!(drainer, :shutdown)
      end

    bandit =
      :loopctl
      |> Application.get_env(LoopctlWeb.Endpoint, [])
      |> get_in([:http, :thousand_island_options, :shutdown_timeout]) || @bandit_shutdown_ms

    oban =
      :loopctl
      |> Application.get_env(Oban, [])
      |> Keyword.get(:shutdown_grace_period, @oban_grace_ms)

    window = Enum.sum(drains) + bandit + oban

    assert kill_timeout_ms > window,
           "kill_timeout #{kill_timeout_ms}ms does not outlast the #{window}ms shutdown window"
  end

  test "the runner socket's drain has room for the shutdown notice" do
    {_path, _socket, opts} =
      Enum.find(LoopctlWeb.Endpoint.__sockets__(), &match?({"/runner/socket", _, _}, &1))

    assert Keyword.fetch!(opts[:drainer], :shutdown) > LoopctlWeb.RunnerShutdownNotice.grace_ms()
  end

  # The `[env]` table, as `KEY = "value"` pairs.
  defp env_table(path) do
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.drop_while(&(String.trim(&1) != "[env]"))
    |> Enum.drop(1)
    |> Enum.take_while(&(not String.starts_with?(String.trim_leading(&1), "[")))
    |> Enum.flat_map(fn line ->
      case Regex.run(~r/^\s*([A-Z_]+)\s*=\s*"([^"]*)"\s*$/, line) do
        [_, key, value] -> [{key, value}]
        _ -> []
      end
    end)
    |> Map.new()
  end

  # A `[section]`'s bare `key = value` pairs (values unquoted, comments dropped).
  defp section(path, name) do
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.drop_while(&(String.trim(&1) != "[#{name}]"))
    |> Enum.drop(1)
    |> Enum.take_while(&(not String.starts_with?(String.trim_leading(&1), "[")))
    |> Enum.flat_map(fn line ->
      case Regex.run(~r/^\s*([a-z_]+)\s*=\s*"?([^"#]*?)"?\s*(#.*)?$/, line) do
        [_, key, value | _] -> [{key, value}]
        _ -> []
      end
    end)
    |> Map.new()
  end

  describe "clustering" do
    test "DNS_CLUSTER_QUERY is the app's own .internal name, in [env]" do
      app = top_level("fly.toml")["app"] |> String.trim(~s("))
      assert env_table("fly.toml")["DNS_CLUSTER_QUERY"] == "#{app}.internal"
    end

    test "EXPECTED_APP_NODES parses to the node count ClusterReadiness and DbCapacity read" do
      value = env_table("fly.toml")["EXPECTED_APP_NODES"]
      assert value, "EXPECTED_APP_NODES is not set in [env]"
      assert {count, ""} = Integer.parse(value)
      assert count > 1
      assert Loopctl.DbCapacity.parse_expected_app_nodes(value) == count
    end

    test "CLUSTER_PEERS_MAY_SUSPEND is true exactly when auto_stop can leave fewer machines running than EXPECTED_APP_NODES" do
      http = section("fly.toml", "http_service")
      expected_nodes = String.to_integer(env_table("fly.toml")["EXPECTED_APP_NODES"])
      min_running = String.to_integer(Map.get(http, "min_machines_running", "0"))
      auto_stop? = Map.get(http, "auto_stop_machines", "off") not in ["off", "false"]

      may_suspend? = auto_stop? and min_running < expected_nodes

      assert Loopctl.ClusterReadiness.parse_peers_may_suspend(
               env_table("fly.toml")["CLUSTER_PEERS_MAY_SUSPEND"]
             ) == may_suspend?,
             "auto_stop_machines=#{inspect(http["auto_stop_machines"])}, " <>
               "min_machines_running=#{min_running}, EXPECTED_APP_NODES=#{expected_nodes}"
    end
  end

  describe "unattended dispatch driver budgets" do
    # #803: the deployed budget must be one `DispatchDriver.normalise_budget/2` ACCEPTS —
    # that function is where the runner contract's own ceiling
    # (`RunnerContract.RunnerDispatch.max_wall_clock_seconds/0`) is read. Over it, nothing is
    # refused per dispatch: the budget read fails before the pass runs, so both workers
    # `{:cancel, ...}` every minute and the driver reads as enabled while placing nothing,
    # visible only in a per-minute ERROR log nobody watches. Lowering the contract maximum
    # below a deployed wall clock is the edit that does it.
    for {var, key} <- [
          {"DISPATCH_WALL_CLOCK_SECONDS", :dispatch_wall_clock_seconds},
          {"DISPATCH_MAX_TURNS", :dispatch_max_turns},
          {"TRIAGE_WALL_CLOCK_SECONDS", :triage_wall_clock_seconds},
          {"TRIAGE_MAX_TURNS", :triage_max_turns}
        ] do
      test "#{var} is inside the bound DispatchDriver enforces" do
        value = env_table("fly.toml")[unquote(var)]
        assert value, "#{unquote(var)} is not set in [env]"
        assert {budget, ""} = Integer.parse(value)

        assert DispatchDriver.normalise_budget(budget, unquote(key)) ==
                 {:ok, budget},
               "#{unquote(var)}=#{budget} is outside the contract bound for #{unquote(key)}"
      end
    end

    # The block's subject is declared cost policy, and this was the one value in it with
    # nothing behind it: set to "99" the whole suite stayed green. Two arms, because the two
    # ways to get it wrong fail in OPPOSITE directions and neither says anything at boot.
    #
    # ARM 1 — the value must be one `config/runtime.exs:161-168` ACCEPTS. That guard is
    # `{sessions, ""} when sessions > 0` and silently leaves the default on anything else, so
    # "0", "two" or a stray "2 " reads as UNSET and RAISES the fleet ceiling to the code
    # default with nothing logged. Mirrored here rather than called because this variable has
    # no parser of its own (unlike EXPECTED_APP_NODES / CLUSTER_PEERS_MAY_SUSPEND above); if
    # the runtime guard ever loosens, this test is merely stricter than production, which is
    # the safe direction.
    #
    # ARM 2 — it may never exceed what NOT SETTING IT would give. This line exists to LOWER
    # the tenant-wide ceiling below the code default; a value above it silently buys more
    # concurrency, and therefore more spend, than deleting the line entirely. Bounded by
    # `Capacity.limit/0` read live rather than by a literal, so 1..default all pass and the
    # policy can rise as the comment in fly.toml says it should — raising it past the default
    # means editing `@default_limit`, which is the deliberate act this is asking for. A bare
    # `<= 2` would freeze today's caution and train people to edit assertions instead.
    test "RUNNER_MAX_IN_FLIGHT_SESSIONS is accepted by runtime.exs and never raises the default" do
      value = env_table("fly.toml")["RUNNER_MAX_IN_FLIGHT_SESSIONS"]
      assert value, "RUNNER_MAX_IN_FLIGHT_SESSIONS is not set in [env]"

      assert {sessions, ""} = Integer.parse(value),
             "#{inspect(value)} is not a bare integer, so runtime.exs silently ignores it " <>
               "and the code default applies"

      assert sessions > 0,
             "#{sessions} is not positive, so runtime.exs silently ignores it and the code " <>
               "default applies"

      refute Application.get_env(:loopctl, :runner_max_in_flight_sessions),
             "the test environment now configures this key, so Capacity.limit/0 below is no " <>
               "longer the CODE default and this bound has quietly moved"

      assert sessions <= Capacity.limit(),
             "#{sessions} is above the code default #{Capacity.limit()}, so " <>
               "this line RAISES the fleet ceiling instead of lowering it — deleting it " <>
               "entirely would cost less"
    end

    # The invariant the deployed lease exists to hold: the runner hard-kills a session at
    # DISPATCH_WALL_CLOCK_SECONDS, so a lease ABOVE that (plus teardown grace) can never
    # release work an agent is still implementing. Inverted, `ReclaimExpiredClaimsWorker`
    # force-unclaims live sessions and the duplicate-work race a claim exists to prevent is
    # back — with nothing in the logs, because releasing a claim is a normal event.
    test "STORY_CLAIM_LEASE_SECONDS outlasts the wall clock the runner kills a session at" do
      env = env_table("fly.toml")

      assert lease_value = env["STORY_CLAIM_LEASE_SECONDS"]
      assert wall_clock_value = env["DISPATCH_WALL_CLOCK_SECONDS"]

      lease = String.to_integer(lease_value)
      wall_clock = String.to_integer(wall_clock_value)

      assert lease > wall_clock,
             "claim lease #{lease}s does not outlast the #{wall_clock}s dispatch wall clock"
    end
  end
end
