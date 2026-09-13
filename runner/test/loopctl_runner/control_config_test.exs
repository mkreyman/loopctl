defmodule LoopctlRunner.ControlConfigTest do
  use ExUnit.Case, async: false

  alias LoopctlRunner.{Config, ControlConfig}
  import LoopctlRunner.TestSupport

  defp control(overrides \\ %{}) do
    Map.merge(
      %{
        "url" => "wss://loopctl.com/runner/socket/websocket",
        "runner_id" => "0b1c7a52-6a4c-4f7e-9d7b-1a2b3c4d5e6f",
        "machine" => "minis",
        "token_file" => "~/.config/loopctl-runner/token",
        "repos" => ["mkreyman/home_care_billing"],
        "max_sessions" => 2
      },
      overrides
    )
  end

  test "a complete control section loads, defaulting the status interval" do
    assert {:ok, %ControlConfig{status_interval_s: 30, machine: "minis"} = c} =
             ControlConfig.from_map(control())

    assert c.token_file == Path.expand("~/.config/loopctl-runner/token")
  end

  test "it is optional in the runner config, and validated when present" do
    root = tmp_dir!("control-config")
    assert {:ok, %Config{control: nil}} = Config.from_map(config_map(root))

    assert {:error, "config control.machine is missing or malformed"} =
             Config.from_map(
               Map.put(config_map(root), "control", control(%{"machine" => "Minis"}))
             )
  end

  describe "the URL" do
    test "must be wss, or ws to loopback" do
      assert {:ok, _} =
               ControlConfig.from_map(
                 control(%{"url" => "ws://127.0.0.1:4030/runner/socket/websocket"})
               )

      for url <- [
            "ws://loopctl.com/runner/socket/websocket",
            "https://loopctl.com",
            "loopctl.com"
          ] do
        assert {:error, "config control.url must be wss://" <> _} =
                 ControlConfig.from_map(control(%{"url" => url}))
      end
    end

    test "may not carry a query string, where a token could leak" do
      assert {:error, "config control.url must carry no query string" <> _} =
               ControlConfig.from_map(
                 control(%{"url" => "wss://loopctl.com/runner/socket/websocket?token=x"})
               )
    end
  end

  test "repos and bounds follow the contract" do
    assert {:error, "config control.repos entries must be owner/repo"} =
             ControlConfig.from_map(control(%{"repos" => ["home_care_billing"]}))

    assert {:error, "config control.max_sessions must be an integer from 0 to 64"} =
             ControlConfig.from_map(control(%{"max_sessions" => 65}))

    assert {:error, "config control.status_interval_s must be an integer from 5 to 3600"} =
             ControlConfig.from_map(control(%{"status_interval_s" => 1}))
  end

  describe "read_token/1" do
    setup do
      {:ok, token_path: Path.join(tmp_dir!("token"), "token")}
    end

    test "reads a file only this user can read", %{token_path: file} do
      File.write!(file, "lc_abc\n")
      File.chmod!(file, 0o600)
      {:ok, c} = ControlConfig.from_map(control(%{"token_file" => file}))
      assert ControlConfig.read_token(c) == {:ok, "lc_abc"}
    end

    test "refuses a group- or world-readable file, an empty one, and a missing one", %{
      token_path: file
    } do
      {:ok, c} = ControlConfig.from_map(control(%{"token_file" => file}))
      assert {:error, "cannot read token file" <> _} = ControlConfig.read_token(c)

      File.write!(file, "lc_abc")
      File.chmod!(file, 0o640)
      assert {:error, msg} = ControlConfig.read_token(c)
      assert msg =~ "readable by other users"

      File.write!(file, "  \n")
      File.chmod!(file, 0o600)
      assert {:error, msg} = ControlConfig.read_token(c)
      assert msg =~ "is empty"
    end
  end

  test "the install preflight refuses a config whose token file is missing" do
    root = tmp_dir!("preflight")
    path = Path.join(root, "runner.json")

    control = %{
      "url" => "wss://loopctl.com/runner/socket/websocket",
      "runner_id" => "0b1c7a52-6a4c-4f7e-9d7b-1a2b3c4d5e6f",
      "machine" => "minis",
      "token_file" => Path.join(root, "token"),
      "repos" => [],
      "max_sessions" => 1
    }

    File.write!(path, JSON.encode!(Map.put(config_map(root), "control", control)))
    System.put_env("LOOPCTL_RUNNER_CONFIG", path)
    on_exit(fn -> System.delete_env("LOOPCTL_RUNNER_CONFIG") end)

    assert {:error, "cannot read token file" <> _} = LoopctlRunner.Application.preflight_check()

    File.write!(Path.join(root, "token"), "lc_x")
    File.chmod!(Path.join(root, "token"), 0o600)
    assert {:ok, ^path} = LoopctlRunner.Application.preflight_check()
  end

  test "the fatal exit status is 78 unless the service overrides it" do
    on_exit(fn -> System.delete_env("LOOPCTL_RUNNER_FATAL_EXIT") end)
    System.delete_env("LOOPCTL_RUNNER_FATAL_EXIT")
    assert LoopctlRunner.Control.fatal_exit_status() == 78

    System.put_env("LOOPCTL_RUNNER_FATAL_EXIT", "0")
    assert LoopctlRunner.Control.fatal_exit_status() == 0

    for bad <- ["", "x", "300", "-1"] do
      System.put_env("LOOPCTL_RUNNER_FATAL_EXIT", bad)
      assert LoopctlRunner.Control.fatal_exit_status() == 78
    end
  end

  test "the launchd agent exits 0 on a fatal refusal and runs the release directly" do
    plist = File.read!(Path.expand("../../rel/launchd/com.loopctl.runner.plist", __DIR__))
    assert plist =~ ~r|<key>LOOPCTL_RUNNER_FATAL_EXIT</key>\s*<string>0</string>|
    assert plist =~ ~r|<string>@RELEASE@/bin/loopctl_runner</string>\s*<string>start</string>|
    refute plist =~ "/bin/sh"

    unit = File.read!(Path.expand("../../rel/systemd/loopctl-runner.service", __DIR__))
    assert unit =~ "RestartPreventExitStatus=78"
    refute unit =~ "LOOPCTL_RUNNER_FATAL_EXIT"
  end

  test "the daemon tags every process's log lines with its runner id" do
    root = tmp_dir!("daemon-tag")
    token = Path.join(root, "token")
    File.write!(token, "lc_x")
    File.chmod!(token, 0o600)

    control = %{
      "url" => "wss://loopctl.example/runner/socket/websocket",
      "runner_id" => "3781bee6-2b97-4df0-9664-7f01a492630f",
      "machine" => "minis",
      "token_file" => token,
      "repos" => ["mkreyman/home_care_billing"],
      "max_sessions" => 1
    }

    path = Path.join(root, "runner.json")
    File.write!(path, JSON.encode!(Map.put(config_map(root), "control", control)))
    System.put_env("LOOPCTL_RUNNER_CONFIG", path)
    %{metadata: before} = :logger.get_primary_config()

    on_exit(fn ->
      System.delete_env("LOOPCTL_RUNNER_CONFIG")
      :logger.update_primary_config(%{metadata: before})
    end)

    assert [{LoopctlRunner.Control, _}] = LoopctlRunner.Application.daemon_children!()

    assert %{metadata: %{runner_id: "3781bee6-2b97-4df0-9664-7f01a492630f"}} =
             :logger.get_primary_config()
  end

  test "the daemon refuses to start without a control section" do
    root = tmp_dir!("daemon")
    path = Path.join(root, "runner.json")
    File.write!(path, JSON.encode!(config_map(root)))
    System.put_env("LOOPCTL_RUNNER_CONFIG", path)
    on_exit(fn -> System.delete_env("LOOPCTL_RUNNER_CONFIG") end)

    assert_raise RuntimeError, ~r/no control section/, fn ->
      LoopctlRunner.Application.daemon_children!()
    end
  end
end
