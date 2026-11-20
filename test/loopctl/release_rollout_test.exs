defmodule Loopctl.ReleaseRolloutTest do
  @moduledoc """
  TC-52.10.4 (US-52.10): `release/rollout.sh` with ssh, gh, npm and curl stubbed as inputs. The
  ssh stub records what each host was asked to install and answers with the status its file
  names; install-machine.sh itself is TC-52.10.1..3's subject.
  """
  use ExUnit.Case, async: true

  @script Path.expand("../../release/rollout.sh", __DIR__)
  @set Loopctl.ReleaseSet.set()
  @mcp Loopctl.ReleaseSet.component("mcp").version

  @ssh """
  #!/usr/bin/env bash
  host=$1; shift
  [ -f "$STUB/$host.down" ] && exit 255
  [ "$*" = true ] && exit 0
  set_id=$(printf '%s' "$*" | grep -oE 'install-machine.sh" [0-9]+' | grep -oE '[0-9]+$')
  server=$(printf '%s' "$*" | grep -oE 'LOOPCTL_FACTORY_SERVER_SET=[0-9]+' | cut -d= -f2)
  echo "$host $set_id $server" >> "$STUB/installs"
  status=$(cat "$STUB/$host.status" 2>/dev/null || echo ok)
  printf '{"host":"%s","set":%s,"status":"%s","runner_version":"0.9","chg_version":"1.0"}\\n' "$host" "$set_id" "$status"
  """

  @gh """
  #!/usr/bin/env bash
  echo "$*" >> "$STUB/gh.log"
  case "$1 $2" in
    "workflow run") touch "$STUB/dispatched" ;;
    "run list") [ -f "$STUB/dispatched" ] && echo 42 || echo 41 ;;
    "run watch") exit "$(cat "$STUB/e2e")" ;;
  esac
  """

  @npm """
  #!/bin/sh
  echo "$*" >> "$STUB/npm.log"
  exit "$(cat "$STUB/npm_exit")"
  """

  @curl """
  #!/bin/sh
  printf '{"release":{"set":%s}}' "$(cat "$STUB/served")"
  """

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    stub = Path.join(tmp, "stub")
    File.mkdir_p!(stub)
    File.write!(Path.join(stub, "e2e"), "0")
    File.write!(Path.join(stub, "served"), to_string(@set))
    File.write!(Path.join(stub, "npm_exit"), "0")

    stub!(stub, "ssh", @ssh)
    stub!(stub, "gh", @gh)
    stub!(stub, "npm", @npm)
    stub!(stub, "curl", @curl)

    env = %{
      "STUB" => stub,
      "ROLLOUT_HOSTS" => "alpha beta",
      "ROLLOUT_SSH" => Path.join(stub, "ssh"),
      "ROLLOUT_GH" => Path.join(stub, "gh"),
      "ROLLOUT_NPM" => Path.join(stub, "npm"),
      "ROLLOUT_CURL" => Path.join(stub, "curl"),
      "ROLLOUT_RUN_WAIT_S" => "3"
    }

    %{env: env, stub: stub}
  end

  test "every host at the set and e2e green exits 0", ctx do
    {out, 0} = rollout(ctx)

    assert installs(ctx) == [["alpha", "#{@set}", "#{@set}"], ["beta", "#{@set}", "#{@set}"]]
    assert out =~ ~r/alpha\s+#{@set}\s+ok/
    assert File.read!(Path.join(ctx.stub, "gh.log")) =~ "run watch 42"
    assert File.read!(Path.join(ctx.stub, "npm.log")) =~ "loopctl-mcp-server@#{@mcp}"
  end

  test "a server on another set stops before any host", ctx do
    File.write!(Path.join(ctx.stub, "served"), to_string(@set - 1))

    {out, 2} = rollout(ctx)
    assert out =~ "deploy first"
    assert installs(ctx) == []
  end

  test "an mcp version npm does not have stops before any host", ctx do
    File.write!(Path.join(ctx.stub, "npm_exit"), "1")

    {out, 2} = rollout(ctx)
    assert out =~ "npm has no loopctl-mcp-server@#{@mcp}"
    assert installs(ctx) == []
  end

  test "an unreachable host is reported, the rest still run, e2e is skipped", ctx do
    File.write!(Path.join(ctx.stub, "alpha.down"), "")

    {out, 1} = rollout(ctx)
    assert out =~ ~r/alpha\s+#{@set}\s+unreachable/
    assert installs(ctx) == [["beta", "#{@set}", "#{@set}"]]
    refute File.exists?(Path.join(ctx.stub, "dispatched"))
  end

  test "a failed host skips e2e", ctx do
    File.write!(Path.join(ctx.stub, "beta.status"), "runner_busy")

    {_, 1} = rollout(ctx)
    refute File.exists?(Path.join(ctx.stub, "dispatched"))
  end

  test "a red e2e rolls back only the hosts this run moved, to the previous set", ctx do
    File.write!(Path.join(ctx.stub, "beta.status"), "unchanged")
    File.write!(Path.join(ctx.stub, "e2e"), "1")

    {out, 1} = rollout(ctx)

    assert out =~ "actions/runs/42"

    assert installs(ctx) ==
             [
               ["alpha", "#{@set}", "#{@set}"],
               ["beta", "#{@set}", "#{@set}"],
               ["alpha", "#{@set - 1}", "#{@set}"]
             ]
  end

  # An ssh that RUNS the remote command here, as the host would, with a `nice` that lists
  # what reached the script's directory instead of running it. Which files install-machine.sh
  # finds beside it is then what rollout.sh actually shipped, whatever mechanism ships them.
  @executing_ssh """
  #!/usr/bin/env bash
  host=$1; shift
  [ "$*" = true ] && exit 0
  ROLLOUT_TEST_HOST=$host PATH="$STUB/bin:$PATH" bash -c "$*"
  """

  @listing_nice """
  #!/usr/bin/env bash
  # nice -n 10 bash <dir>/install-machine.sh <set>
  dir=$(dirname "$4")
  (cd "$dir" && find . -type f | sed 's|^\\./||' | sort) > "$STUB/$ROLLOUT_TEST_HOST.shipped"
  printf '{"host":"%s","set":%s,"status":"ok","runner_version":"0.9","chg_version":"1.0"}\\n' "$ROLLOUT_TEST_HOST" "$5"
  """

  test "every file install-machine.sh runs from release/lib reaches the host", ctx do
    stub!(ctx.stub, "ssh", @executing_ssh)
    File.mkdir_p!(Path.join(ctx.stub, "bin"))
    stub!(Path.join(ctx.stub, "bin"), "nice", @listing_nice)

    {_, 0} = rollout(ctx)

    lib = Path.expand("../../release/lib", __DIR__)

    expected =
      lib
      |> File.ls!()
      |> Enum.reject(&(&1 == "__pycache__"))
      |> Enum.map(&("lib/" <> &1))
      |> Kernel.++(["install-machine.sh"])
      |> Enum.sort()

    assert "lib/drop_retired_sources.py" in expected
    assert "lib/rewrite_runner_config.py" in expected

    for host <- ~w(alpha beta) do
      shipped = ctx.stub |> Path.join("#{host}.shipped") |> File.read!() |> String.split()
      assert shipped == expected
    end
  end

  defp rollout(ctx), do: System.cmd("bash", [@script], env: ctx.env, stderr_to_stdout: true)

  defp installs(ctx) do
    case File.read(Path.join(ctx.stub, "installs")) do
      {:ok, body} -> body |> String.split("\n", trim: true) |> Enum.map(&String.split/1)
      {:error, :enoent} -> []
    end
  end

  defp stub!(dir, name, body) do
    path = Path.join(dir, name)
    File.write!(path, body)
    File.chmod!(path, 0o755)
  end
end
