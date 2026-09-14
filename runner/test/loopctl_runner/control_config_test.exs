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

  describe "release pruning (rel/install.sh)" do
    @script Path.expand("../../rel/install.sh", __DIR__)

    defp releases(prefix, stamps, current, history) do
      for stamp <- stamps, do: File.mkdir_p!(Path.join([prefix, "releases", stamp, "bin"]))
      File.ln_s!(Path.join([prefix, "releases", current]), Path.join(prefix, "current"))

      if history,
        do: File.write!(Path.join(prefix, "history"), Enum.map_join(history, &(&1 <> "\n")))
    end

    defp prune(prefix, keep \\ "3") do
      env = [{"LOOPCTL_RUNNER_PREFIX", prefix}, {"LOOPCTL_RUNNER_KEEP_RELEASES", keep}]
      System.cmd("bash", [@script, "--prune"], env: env, stderr_to_stdout: true)
    end

    defp left(prefix), do: prefix |> Path.join("releases") |> File.ls!() |> Enum.sort()

    test "without a history, the newest by name are kept, and always the current one" do
      prefix = tmp_dir!("prune-plain")
      stamps = ~w(r01 r02 r03 r04 r05 r06)
      releases(prefix, stamps, "r02", nil)

      assert {out, 0} = prune(prefix)
      assert out =~ "pruned release r01"
      assert left(prefix) == ~w(r02 r05 r06)
    end

    test "failed builds never current do not push out the last release that ran" do
      prefix = tmp_dir!("prune-failed")
      # r01 ran; r02-r04 failed preflight and were left behind; r05 installed over r01.
      releases(prefix, ~w(r01 r02 r03 r04 r05), "r05", ~w(r01 r05))

      # Both releases that ran are kept; name order only fills the third slot.
      assert {_out, 0} = prune(prefix)
      assert left(prefix) == ~w(r01 r04 r05)
    end

    test "a history shorter than the keep count is filled with the newest by name" do
      prefix = tmp_dir!("prune-short")
      # The first install on a machine that predates the history file.
      releases(prefix, ~w(r1 r2 r3 r4 r5 r6), "r6", ~w(r5 r6))

      assert {_out, 0} = prune(prefix)
      assert left(prefix) == ~w(r4 r5 r6)
    end

    test "the oldest history entry being gone from disk does not stop pruning" do
      prefix = tmp_dir!("prune-oldest-gone")
      # What every install after the fourth sees: history still names the pruned r01.
      releases(prefix, ~w(r02 r03 r04 r05 r06), "r06", ~w(r01 r02 r03 r04 r05 r06))

      assert {out, 0} = prune(prefix)
      assert out =~ "pruned release r02"
      assert left(prefix) == ~w(r04 r05 r06)
    end

    test "a release rolled back to survives the next install" do
      prefix = tmp_dir!("prune-rollback")
      # r02-r06 installed in turn, current rolled back to r02, then r07 installed over it.
      releases(prefix, ~w(r02 r03 r04 r05 r06 r07), "r07", ~w(r02 r03 r04 r05 r06 r02 r07))

      assert {_out, 0} = prune(prefix)
      assert left(prefix) == ~w(r02 r06 r07)
    end

    test "a release already gone from disk does not take a kept release's place" do
      prefix = tmp_dir!("prune-gone")
      # r08 was pruned by hand; counting it would leave only two real releases kept.
      releases(prefix, ~w(r03 r04 r05 r06), "r06", ~w(r04 r05 r08))

      assert {_out, 0} = prune(prefix)
      assert left(prefix) == ~w(r04 r05 r06)
    end

    test "a keep count of zero in any spelling, or a prefix the unit cannot carry, is refused" do
      prefix = tmp_dir!("prune-refuse")
      releases(prefix, ~w(r01 r02 r03), "r03", nil)

      # An empty value is unset, and means the default.
      for keep <- ["0", "00", "3x"] do
        assert {out, 1} = prune(prefix, keep)
        assert out =~ "must be a positive integer"
      end

      assert left(prefix) == ~w(r01 r02 r03)
      assert {out, 1} = prune(prefix <> "/with space")
      assert out =~ "cannot carry"
    end

    test "a prune waits its turn behind a running install, and takes over a dead one's lock" do
      prefix = tmp_dir!("prune-lock")
      releases(prefix, ~w(r0 r1 r2 r3), "r2", ~w(r0 r1 r1 r2))
      lock = Path.join(prefix, ".install.lock")

      # An install still building r3 holds the lock: its pid is this live test process.
      File.mkdir_p!(lock)
      File.write!(Path.join(lock, "pid"), System.pid())

      assert {out, 1} = prune(prefix)
      assert out =~ "another install or prune is running"
      assert "r3" in left(prefix)

      # Its owner died: the lock is taken over, and released when the prune exits.
      File.write!(Path.join(lock, "pid"), "999999999")
      assert {_out, 0} = prune(prefix)
      refute File.exists?(lock)
    end

    test "an install takes the lock before it builds" do
      script = File.read!(@script)
      assert script =~ ~r/take_lock\nstamp=\$\(date -u/
    end

    test "an install records the release it replaces and the new one, then prunes" do
      script = File.read!(@script)

      assert script =~
               ~r/echo "\$previous" >> "\$prefix\/history"\nln -sfn "\$prefix\/releases\/\$stamp" "\$prefix\/current"\necho "\$stamp" >> "\$prefix\/history"/

      assert script =~ ~r/echo "installed \$prefix\/releases\/\$stamp"\nprune_releases\n/
    end
  end

  test "the launchd agent exits 0 on a fatal refusal and runs the release directly" do
    plist = File.read!(Path.expand("../../rel/launchd/com.loopctl.runner.plist", __DIR__))
    assert plist =~ ~r|<key>LOOPCTL_RUNNER_FATAL_EXIT</key>\s*<string>0</string>|
    assert plist =~ ~r|<string>@RELEASE@/bin/loopctl_runner</string>\s*<string>start</string>|
    refute plist =~ "/bin/sh"

    unit = File.read!(Path.expand("../../rel/systemd/loopctl-runner.service", __DIR__))
    assert unit =~ "RestartPreventExitStatus=78"
    # A stop rpc from the newly installed release would carry the wrong cookie; SIGTERM stops it.
    refute unit =~ ~r/^ExecStop=/m
    # SIGTERM to the BEAM alone, so it ends its sessions itself before anything else is killed.
    assert unit =~ ~r/^KillMode=mixed$/m
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

    # The run supervisor starts first, so it exists whenever Control accepts a dispatch.
    assert [
             {Task.Supervisor, [name: LoopctlRunner.RunSupervisor]},
             {LoopctlRunner.Control, control_opts}
           ] = LoopctlRunner.Application.daemon_children!()

    assert control_opts[:run_supervisor] == LoopctlRunner.RunSupervisor

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
