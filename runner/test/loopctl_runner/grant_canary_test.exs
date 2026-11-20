defmodule LoopctlRunner.GrantCanaryTest do
  use ExUnit.Case, async: true

  alias LoopctlRunner.{GitGrant, GrantCanary, Owner}

  import LoopctlRunner.TestSupport

  # A live os process that is not this BEAM, by its full identity; ended when the test is.
  defp live_process! do
    port =
      Port.open({:spawn_executable, System.find_executable("sleep")}, [:exit_status, args: ["60"]])

    {:os_pid, pid} = Port.info(port, :os_pid)
    on_exit(fn -> System.cmd("kill", ["-9", "#{pid}"], stderr_to_stdout: true) end)
    {port, Owner.of(pid)}
  end

  setup do
    dir = tmp_dir!("grant-canary")
    {:ok, dir: dir, grant: &Path.join(dir, GitGrant.prefix() <> &1)}
  end

  test "a grant or pending file this BEAM left is a breach; another live BEAM's is not", ctx do
    {_port, other} = live_process!()
    File.write!(ctx.grant.("ours"), GitGrant.line("ours", granted(owner!())))
    pending = Path.join(ctx.dir, GitGrant.pending_prefix() <> "ours-pending")
    File.write!(pending, GitGrant.line("ours-pending", granted(owner!())))
    File.write!(ctx.grant.("theirs"), GitGrant.line("theirs", other, other))

    assert Enum.sort(GrantCanary.violations([], ctx.dir, owner!())) ==
             Enum.sort([{:left, ctx.grant.("ours")}, {:left, pending}])
  end

  test "a live session's grant gone by the end is a breach; one whose session ended is not",
       ctx do
    {_port, owner} = live_process!()
    {port, launcher} = live_process!()
    {_port, running} = live_process!()

    File.write!(ctx.grant.("in-flight"), GitGrant.line("in-flight", owner, running))
    File.write!(ctx.grant.("finished"), GitGrant.line("finished", owner, launcher))
    File.write!(ctx.grant.("still-there"), GitGrant.line("still-there", owner, running))
    # No session line: its owner outlives its session, so its removal says nothing.
    File.write!(ctx.grant.("owner-only"), GitGrant.line("owner-only", owner))
    snapshot = GrantCanary.snapshot(ctx.dir)

    File.rm!(ctx.grant.("in-flight"))
    File.rm!(ctx.grant.("owner-only"))
    # The finished session: its tree ended, then its teardown removed its grant.
    System.cmd("kill", ["-9", "#{launcher["beam_os_pid"]}"])
    assert_receive {^port, {:exit_status, _}}, 5_000
    File.rm!(ctx.grant.("finished"))

    assert GrantCanary.violations(snapshot, ctx.dir, owner!()) ==
             [{:removed, ctx.grant.("in-flight")}]
  end
end
