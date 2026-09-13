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
  end
end
