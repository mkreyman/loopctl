defmodule Loopctl.ReleaseInstallMachineTest do
  @moduledoc """
  TC-52.10.1..3 (US-52.10): `release/install-machine.sh` against a fixture repository whose
  tags carry stub runner and chg installers, every path an environment input under the test's
  own `tmp_dir`.
  """
  use ExUnit.Case, async: true

  @script Path.expand("../../release/install-machine.sh", __DIR__)

  # A runner installer that "restarts" the runner: it writes the binary the drain talks to and
  # the joined.json the runner writes once loopctl admits its join, naming the stub's set.
  @runner_install """
  #!/usr/bin/env bash
  set -eu
  [ -f "$STUB/runner_install_fails" ] && exit 1
  # A Mac's non-interactive ssh: mix only through asdf's shims under HOME.
  [ -f "$STUB/needs_shim_mix" ] && [ "$(command -v mix)" != "$HOME/.asdf/shims/mix" ] && exit 1
  mkdir -p "$LOOPCTL_RUNNER_PREFIX/current/bin"
  cat > "$LOOPCTL_RUNNER_PREFIX/current/bin/loopctl_runner" <<'BIN'
  #!/usr/bin/env bash
  case $1 in
    pid) [ -f "$STUB/running" ] ;;
    rpc) echo "$2" >> "$STUB/rpc.log"
         case $2 in *runs_in_flight*) cat "$STUB/in_flight" ;; esac ;;
  esac
  BIN
  chmod +x "$LOOPCTL_RUNNER_PREFIX/current/bin/loopctl_runner"
  echo installed >> "$STUB/runner_installs"
  [ -f "$STUB/no_join" ] && exit 0
  printf '{"runner_version":"0.9.%s","release_set":%s}' "$(cat ../SET)" "$(cat "$STUB/server_set")" > "$STUB/state/joined.json"
  """

  @chg_install """
  #!/usr/bin/env bash
  set -eu
  dest=$2
  mkdir -p "$dest"
  sha=$(git rev-parse --short=12 HEAD)
  cat > "$dest/chg" <<BIN
  #!/bin/sh
  echo "\\$*" >> "\\$STUB/chg.log"
  case "\\$1" in
    outbox) [ -f "\\$STUB/send_fails" ] && exit 1; exit 0 ;;
  esac
  echo "chg $(cat ../SET).0.0 (adapter contract 1, commit $sha)"
  BIN
  chmod +x "$dest/chg"
  """

  setup %{tmp_dir: tmp} do
    stub = Path.join(tmp, "stub")
    home = Path.join(tmp, "home")
    File.mkdir_p!(Path.join(stub, "state"))
    File.mkdir_p!(home)
    File.write!(Path.join(stub, "in_flight"), "0\n")

    origin = Path.join(tmp, "origin.git")
    work = Path.join(tmp, "work")
    git!(tmp, ["init", "--quiet", "--bare", origin])
    git!(tmp, ["init", "--quiet", "-b", "master", work])

    for set <- 1..5, do: tag_set!(work, set)
    git!(work, ["push", "--quiet", origin, "master", "--tags"])

    config = Path.join(home, "runner.json")

    File.write!(
      config,
      Jason.encode!(%{
        "runs_dir" => Path.join([stub, "state", "runs"]),
        "repos" => %{"chg" => "~/workspace/chg"},
        "control" => %{"repos" => ["mkreyman/home_care_billing", "mkreyman/chg"]},
        "selection_replay" => %{"chg" => %{"product" => "hcb", "paths" => ["cli/src/cover.rs"]}}
      })
    )

    env = %{
      "HOME" => home,
      "STUB" => stub,
      "LOOPCTL_FACTORY_HOME" => Path.join(tmp, "factory"),
      "LOOPCTL_FACTORY_REPO" => origin,
      "LOOPCTL_RUNNER_PREFIX" => Path.join(tmp, "runner"),
      "LOOPCTL_RUNNER_CONFIG" => config,
      "LOOPCTL_FACTORY_CHG_DEST" => Path.join([home, "bin", "chg"]),
      "LOOPCTL_FACTORY_CHG_SYSTEM" => Path.join([tmp, "system", "chg"]),
      "LOOPCTL_FACTORY_CHECKOUT" => Path.join(home, "loopctl"),
      "LOOPCTL_FACTORY_CHG_CONFIG" => Path.join(tmp, "loopctl.toml"),
      "LOOPCTL_FACTORY_POLL_S" => "1",
      "LOOPCTL_FACTORY_JOIN_S" => "2",
      "LOOPCTL_FACTORY_DRAIN_S" => "2"
    }

    %{env: env, stub: stub, factory: env["LOOPCTL_FACTORY_HOME"], config: config, tmp: tmp}
  end

  @moduletag :tmp_dir

  describe "TC-52.10.1: set checkout, symlink swap, retention and lock" do
    test "checks the tag out into sets/<set> and points current at it", ctx do
      {out, 0} = install(ctx, 2)

      assert %{"status" => "ok", "set" => 2, "chg_version" => "2.0.0"} = out
      assert File.read_link!(Path.join(ctx.factory, "current")) == "sets/2"
      assert File.read!(Path.join([ctx.factory, "sets", "2", "SET"])) == "2"
    end

    test "keeps the three newest sets", ctx do
      for set <- 1..5, do: {%{"status" => "ok"}, 0} = install(ctx, set)

      assert ctx.factory |> Path.join("sets") |> File.ls!() |> Enum.sort() == ~w(3 4 5)
      assert File.read_link!(Path.join(ctx.factory, "current")) == "sets/5"
    end

    test "a second run while one holds the lock exits 75 busy", ctx do
      lock = Path.join(ctx.factory, ".install.lock")
      File.mkdir_p!(lock)
      # This test's own BEAM is alive, so the lock reads as held.
      File.write!(Path.join(lock, "pid"), System.pid())

      {out, 75} = install(ctx, 2)
      assert out["status"] == "busy"
    end

    test "a lock whose owner is gone is taken over", ctx do
      lock = Path.join(ctx.factory, ".install.lock")
      File.mkdir_p!(lock)
      File.write!(Path.join(lock, "pid"), "999999999")

      assert {%{"status" => "ok"}, 0} = install(ctx, 2)
    end

    test "a stale lock another run replaced before the takeover is put back, and busy", ctx do
      lock = Path.join(ctx.factory, ".install.lock")
      File.mkdir_p!(lock)
      File.write!(Path.join(lock, "pid"), "999999999")

      # Between this run judging the lock stale and renaming it, another run takes it over:
      # the stub `mv` writes that run's live pid (this BEAM) into the lock, then moves it.
      bin = Path.join(ctx.stub, "racebin")
      File.mkdir_p!(bin)
      real_path = System.get_env("PATH")

      script!(Path.join(bin, "mv"), """
      #!/bin/sh
      case "$1" in
        *.install.lock) [ -f "$STUB/raced" ] || { touch "$STUB/raced"; echo #{System.pid()} > "$1/pid"; } ;;
      esac
      PATH="#{real_path}" exec mv "$@"
      """)

      {out, 75} = install(ctx, 2, env: %{"PATH" => "#{bin}:#{real_path}"})
      assert out["status"] == "busy"
      assert File.read!(Path.join(lock, "pid")) |> String.trim() == System.pid()
      refute File.exists?(Path.join(ctx.factory, "current"))
    end

    test "an old pidless lock recreated by another run before the takeover is put back", ctx do
      lock = Path.join(ctx.factory, ".install.lock")
      File.mkdir_p!(lock)
      File.touch!(lock, System.os_time(:second) - 600)

      # Between this run judging the pidless lock stale and renaming it, another run took it
      # over and made a fresh lock, which has no pid yet either.
      bin = Path.join(ctx.stub, "racebin")
      File.mkdir_p!(bin)
      real_path = System.get_env("PATH")

      script!(Path.join(bin, "mv"), """
      #!/bin/sh
      case "$1" in
        *.install.lock) [ -f "$STUB/raced" ] || { touch "$STUB/raced"; rm -rf "$1"; mkdir "$1"; } ;;
      esac
      PATH="#{real_path}" exec mv "$@"
      """)

      {out, 75} = install(ctx, 2, env: %{"PATH" => "#{bin}:#{real_path}"})
      assert out["status"] == "busy"
      assert File.dir?(lock)
      refute File.exists?(Path.join(ctx.factory, "current"))
    end

    test "a fresh lock with no pid yet is busy, not a dead owner", ctx do
      # The window between the owner's mkdir and its pid write.
      lock = Path.join(ctx.factory, ".install.lock")
      File.mkdir_p!(lock)

      {out, 75} = install(ctx, 2)
      assert out["status"] == "busy"
      assert File.dir?(lock)
      refute File.exists?(Path.join(ctx.factory, "current"))
    end

    test "a lock with no pid older than the bound is taken over", ctx do
      lock = Path.join(ctx.factory, ".install.lock")
      File.mkdir_p!(lock)
      old = System.os_time(:second) - 600
      File.touch!(lock, old)

      assert {%{"status" => "ok"}, 0} = install(ctx, 2)
    end

    test "a finished install releases its lock", ctx do
      {%{"status" => "ok"}, 0} = install(ctx, 2)
      refute File.exists?(Path.join(ctx.factory, ".install.lock"))
    end

    test "a set with no tag fails and leaves current alone", ctx do
      {%{"status" => "ok"}, 0} = install(ctx, 2)
      {out, 1} = install(ctx, 9)

      assert out["status"] == "failed"
      assert out["detail"] =~ "factory-9"
      assert File.read_link!(Path.join(ctx.factory, "current")) == "sets/2"
    end
  end

  describe "TC-52.10.2: drain wait and runner_busy" do
    test "a running runner is drained before it is replaced", ctx do
      {%{"status" => "ok"}, 0} = install(ctx, 2)
      File.write!(Path.join(ctx.stub, "running"), "")

      {%{"status" => "ok"}, 0} = install(ctx, 3)
      log = File.read!(Path.join(ctx.stub, "rpc.log"))

      assert log =~ "set_draining(LoopctlRunner.Control, true)"
      refute log =~ "set_draining(LoopctlRunner.Control, false)"
    end

    test "a runner still busy at the deadline is undrained and nothing changes", ctx do
      {%{"status" => "ok"}, 0} = install(ctx, 2)
      File.write!(Path.join(ctx.stub, "running"), "")
      File.write!(Path.join(ctx.stub, "in_flight"), "1\n")

      {out, 1} = install(ctx, 3)

      assert out["status"] == "runner_busy"

      assert File.read!(Path.join(ctx.stub, "rpc.log")) =~
               "set_draining(LoopctlRunner.Control, false)"

      assert File.read_link!(Path.join(ctx.factory, "current")) == "sets/2"

      assert ctx.stub |> Path.join("runner_installs") |> File.read!() |> String.split() == [
               "installed"
             ]
    end

    test "a failed runner.json rewrite after the drain undrains the runner", ctx do
      {%{"status" => "ok"}, 0} = install(ctx, 2)
      File.write!(Path.join(ctx.stub, "running"), "")
      File.write!(ctx.config, "not json")

      {out, 1} = install(ctx, 3)

      assert out["status"] == "failed"
      assert out["detail"] =~ "cannot rewrite"
      assert undrained?(ctx)
    end

    test "a failed runner install after the drain undrains the runner", ctx do
      {%{"status" => "ok"}, 0} = install(ctx, 2)
      File.write!(Path.join(ctx.stub, "running"), "")
      File.write!(Path.join(ctx.stub, "runner_install_fails"), "")

      {out, 1} = install(ctx, 3)

      assert out["status"] == "failed"
      assert out["detail"] =~ "the runner install failed"
      assert undrained?(ctx)
      assert File.read_link!(Path.join(ctx.factory, "current")) == "sets/2"
    end

    test "a failure after the new runner is up does not undrain it", ctx do
      {%{"status" => "ok"}, 0} = install(ctx, 2)
      File.write!(Path.join(ctx.stub, "running"), "")
      File.write!(Path.join(ctx.stub, "no_join"), "")

      {%{"status" => "failed"}, 1} = install(ctx, 3)

      log = File.read!(Path.join(ctx.stub, "rpc.log"))
      assert log =~ "set_draining(LoopctlRunner.Control, true)"
      refute log =~ "set_draining(LoopctlRunner.Control, false)"
    end

    defp undrained?(ctx) do
      lines = ctx.stub |> Path.join("rpc.log") |> File.read!() |> String.split("\n", trim: true)

      drain = Enum.find_index(lines, &(&1 =~ "set_draining(LoopctlRunner.Control, true)"))
      undrain = Enum.find_index(lines, &(&1 =~ "set_draining(LoopctlRunner.Control, false)"))
      is_integer(drain) and is_integer(undrain) and undrain > drain
    end
  end

  describe "TC-52.10.3: installs into the existing prefixes and verifies the join" do
    test "a machine already at the set prints unchanged and reinstalls nothing", ctx do
      {%{"status" => "ok"}, 0} = install(ctx, 2)
      {out, 0} = install(ctx, 2)

      assert out["status"] == "unchanged"

      assert ctx.stub |> Path.join("runner_installs") |> File.read!() |> String.split() == [
               "installed"
             ]
    end

    test "a runner that never joins at the set fails the install", ctx do
      File.write!(Path.join(ctx.stub, "no_join"), "")

      {out, 1} = install(ctx, 2)
      assert out["status"] == "failed"
      assert out["detail"] =~ "did not join loopctl at release_set 2"
    end

    test "a runner with no state directory yet joins once the install creates it", ctx do
      File.rm_rf!(Path.join(ctx.stub, "state"))

      {out, 0} = install(ctx, 2)
      assert out["status"] == "ok"
      assert File.exists?(Path.join([ctx.stub, "state", "joined.json"]))
    end

    test "a python3 without tomllib is passed over for one that has it", ctx do
      bin = Path.join(ctx.tmp, "pybin")
      File.mkdir_p!(bin)
      # macOS's /usr/bin/python3 is 3.9: first on PATH, and no tomllib.
      File.write!(Path.join(bin, "python3"), "#!/bin/sh\nexit 1\n")
      File.chmod!(Path.join(bin, "python3"), 0o755)
      File.ln_s!(System.find_executable("python3"), Path.join(bin, "python3.11"))

      {out, 0} = install(ctx, 2, env: %{"PATH" => "#{bin}:#{System.get_env("PATH")}"})
      assert out["status"] == "ok"
    end

    test "asdf's shims under HOME are on PATH for the runner build", ctx do
      shims = Path.join([ctx.env["HOME"], ".asdf", "shims"])
      File.mkdir_p!(shims)
      File.write!(Path.join(shims, "mix"), "#!/bin/sh\nexit 0\n")
      File.chmod!(Path.join(shims, "mix"), 0o755)
      File.write!(Path.join(ctx.stub, "needs_shim_mix"), "")

      {out, 0} = install(ctx, 2)
      assert out["status"] == "ok"
    end

    test "a join naming another set is not the set", ctx do
      {out, 1} = install(ctx, 2, server_set: 7)

      assert out["status"] == "failed"
    end

    test "a rollback waits for the server's set, not the one it installs", ctx do
      {%{"status" => "ok"}, 0} = install(ctx, 3, server_set: 3)

      assert {%{"status" => "ok", "set" => 2}, 0} =
               install(ctx, 2, server_set: 3, env: %{"LOOPCTL_FACTORY_SERVER_SET" => "3"})
    end

    test "a system chg install that is stale fails the set", ctx do
      system = ctx.env["LOOPCTL_FACTORY_CHG_SYSTEM"]
      File.mkdir_p!(Path.dirname(system))

      File.write!(
        system,
        "#!/bin/sh\necho 'chg 0.0.1 (adapter contract 1, commit 000000000000)'\n"
      )

      File.chmod!(system, 0o755)

      {out, 1} = install(ctx, 2)
      assert out["status"] == "failed"
      assert out["detail"] =~ "chg --version does not name 2.0.0"
      assert File.read!(Path.join(ctx.stub, "system_installs")) == "system\n"
    end

    test "a system chg already at the set is not reinstalled (its sudo may need a terminal)",
         ctx do
      {sha, 0} =
        System.cmd("git", ["rev-parse", "--short=12", "factory-2^{commit}"],
          cd: Path.join(ctx.tmp, "work")
        )

      system = ctx.env["LOOPCTL_FACTORY_CHG_SYSTEM"]
      File.mkdir_p!(Path.dirname(system))

      File.write!(
        system,
        "#!/bin/sh\necho 'chg 2.0.0 (adapter contract 1, commit #{String.trim(sha)})'\n"
      )

      File.chmod!(system, 0o755)

      {out, 0} = install(ctx, 2)
      assert out["status"] == "ok"
      refute File.exists?(Path.join(ctx.stub, "system_installs"))
    end

    test "a failed system install says how to run its sudo step by hand", ctx do
      system = ctx.env["LOOPCTL_FACTORY_CHG_SYSTEM"]
      File.mkdir_p!(Path.dirname(system))
      File.write!(system, "#!/bin/sh\necho 'chg 0.0.1 (adapter contract 1, commit 0)'\n")
      File.chmod!(system, 0o755)
      File.write!(Path.join(ctx.stub, "system_install_fails"), "")

      {out, 1} = install(ctx, 2)
      assert out["detail"] =~ "ssh -t <host> 'PATH=$HOME/.asdf/shims:"
      assert out["detail"] =~ "scripts/install-system.sh'"
    end

    test "runner.json moves from mkreyman/chg to mkreyman/loopctl", ctx do
      {%{"status" => "ok"}, 0} = install(ctx, 2)
      config = ctx.config |> File.read!() |> Jason.decode!()

      assert config["control"]["repos"] == ["mkreyman/home_care_billing", "mkreyman/loopctl"]

      assert config["selection_replay"] == %{
               "loopctl" => %{"product" => "hcb", "paths" => ["chg/cli/src/cover.rs"]}
             }

      assert config["repos"]["loopctl"] == ctx.env["LOOPCTL_FACTORY_CHECKOUT"]
    end
  end

  describe "a machine with no runner.json runs no runner" do
    setup ctx do
      File.rm!(ctx.config)
      :ok
    end

    test "installs the set and chg, installs no runner and waits for no join", ctx do
      {out, 0} = install(ctx, 2)

      assert %{"status" => "ok", "chg_version" => "2.0.0", "runner_version" => nil} = out
      assert File.read_link!(Path.join(ctx.factory, "current")) == "sets/2"
      refute File.exists?(Path.join(ctx.stub, "runner_installs"))
      refute File.exists?(ctx.config)
    end

    test "a second run at the set is unchanged", ctx do
      {%{"status" => "ok"}, 0} = install(ctx, 2)

      assert {%{"status" => "unchanged", "runner_version" => nil}, 0} = install(ctx, 2)
    end
  end

  describe "TC-52.11.4: a retired repo's chg sources go once their rows are sent" do
    @sources """
    [[source]]
    repo = "mkreyman/chg"
    source_id = "7c2ca807"
    secret_file = "/s/chg"

    [[source]]
    repo = "mkreyman/reportex"
    source_id = "3fd6d7d5"
    secret_file = "/s/reportex"
    """

    test "sends the outbox, then removes the retired block", ctx do
      config = chg_config(ctx)

      {%{"status" => "ok"}, 0} = install(ctx, 2)

      assert File.read!(Path.join(ctx.stub, "chg.log")) =~ "outbox send"
      refute File.read!(config) =~ "mkreyman/chg"
      assert File.read!(config) =~ ~s(repo = "mkreyman/reportex")
    end

    test "a failed send keeps the sources and fails; a machine already at the set retries", ctx do
      config = chg_config(ctx)
      File.write!(Path.join(ctx.stub, "send_fails"), "")

      {out, 1} = install(ctx, 2)
      assert out["detail"] =~ "chg outbox send failed"
      assert File.read!(config) == @sources

      File.rm!(Path.join(ctx.stub, "send_fails"))
      {%{"status" => "unchanged"}, 0} = install(ctx, 2)
      refute File.read!(config) =~ "mkreyman/chg"
    end

    test "with nothing to remove, the outbox is not sent", ctx do
      {%{"status" => "ok"}, 0} = install(ctx, 2)
      refute File.read!(Path.join(ctx.stub, "chg.log")) =~ "outbox"
    end

    defp chg_config(ctx) do
      path = Path.join(ctx.tmp, "loopctl.toml")
      File.write!(path, @sources)
      File.write!(Path.join(ctx.stub, "chg_config"), path)
      path
    end
  end

  defp install(ctx, set, opts \\ []) do
    File.write!(Path.join(ctx.stub, "server_set"), to_string(Keyword.get(opts, :server_set, set)))
    env = Map.merge(ctx.env, Keyword.get(opts, :env, %{}))

    {out, code} = System.cmd("bash", [@script, to_string(set)], env: env, stderr_to_stdout: false)
    {out |> String.split("\n", trim: true) |> List.last() |> Jason.decode!(), code}
  end

  defp tag_set!(work, set) do
    File.write!(Path.join(work, "SET"), to_string(set))
    File.mkdir_p!(Path.join(work, "release"))

    File.write!(
      Path.join([work, "release", "manifest.toml"]),
      "set = #{set}\n\n[components.chg]\nversion = \"#{set}.0.0\"\n\n" <>
        "[retired]\nrepos = [\"mkreyman/chg\"]\n"
    )

    script!(Path.join([work, "runner", "rel", "install.sh"]), @runner_install)
    script!(Path.join([work, "chg", "scripts", "install.sh"]), @chg_install)
    # Refreshes nothing, so a stale system install stays stale and verification must catch it.
    script!(
      Path.join([work, "chg", "scripts", "install-system.sh"]),
      "#!/bin/sh\n[ -f \"$STUB/system_install_fails\" ] && exit 1\necho system >> \"$STUB/system_installs\"\n"
    )

    git!(work, ["add", "SET", "release", "runner", "chg"])

    git!(work, [
      "-c",
      "user.name=t",
      "-c",
      "user.email=t@t",
      "commit",
      "--quiet",
      "-m",
      "set #{set}"
    ])

    git!(work, ["tag", "factory-#{set}"])
  end

  defp script!(path, body) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, body)
    File.chmod!(path, 0o755)
  end

  defp git!(dir, args) do
    {_, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
  end
end
