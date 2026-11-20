defmodule LoopctlRunner.StartTimeTest do
  # A reader in another timezone is an environment PASSED to the reading, never this BEAM's own
  # changed, so these run alongside anything.
  use ExUnit.Case, async: true

  alias LoopctlRunner.{Owner, ProcessGroup}
  import LoopctlRunner.TestSupport

  @far_tz LoopctlRunner.TestSupport.far_timezone()
  if @far_tz == nil, do: @moduletag(skip: "this host's tz database lacks Pacific/Kiritimati")

  setup_all do
    {:ok, far: [{"TZ", @far_tz}]}
  end

  # A live group leader, as the session launcher is one, ended when the test is.
  defp live_leader! do
    port =
      Port.open({:spawn_executable, System.find_executable("perl")}, [
        :exit_status,
        args: ["-MPOSIX", "-e", "POSIX::setsid(); exec 'sleep', '60'"]
      ])

    {:os_pid, pid} = Port.info(port, :os_pid)
    on_exit(fn -> System.cmd("kill", ["-9", "#{pid}"], stderr_to_stdout: true) end)
    :ok = wait_until(fn -> ProcessGroup.leader?(pid) end)
    pid
  end

  defp tree_file!(label, line) do
    file = Path.join(tmp_dir!(label), "stderr.log.tree")
    File.write!(file, line <> "\n")
    file
  end

  test "a process's start reads the same whatever timezone the reader runs in", ctx do
    pid = live_leader!()
    started = LoopctlRunner.TestSupport.utc_start_time(pid)
    assert started =~ ~r/\Autc:/
    assert LoopctlRunner.TestSupport.utc_start_time(pid, ctx.far) == started
    # What that reader's own zone would have recorded instead: fourteen hours away.
    refute "utc:" <> Owner.local_start_time(pid, ctx.far) == started
  end

  test "a tagged record is compared only in its own form, never by the reader's local rendering",
       ctx do
    pid = live_leader!()
    # The pid's start as the far reader's zone renders it, carrying a tag it does not match.
    file = tree_file!("tagged-tree", "#{pid} utc:#{Owner.local_start_time(pid, ctx.far)}")
    assert ProcessGroup.recorded(file, ctx.far) == []
  end

  test "a tree file line a runner before #66 wrote, in its own timezone, is still recognised",
       ctx do
    pid = live_leader!()
    file = tree_file!("legacy-tree", "#{pid} #{Owner.local_start_time(pid, ctx.far)}")
    assert ProcessGroup.recorded(file, ctx.far) == [pid]
    # Read by a reader in another zone, the same legacy line names nobody.
    assert ProcessGroup.recorded(file) == []
  end

  test "a leader_start a runner before #66 wrote, in its own timezone, still names the group",
       ctx do
    pid = live_leader!()
    legacy = Owner.local_start_time(pid, ctx.far)

    assert ProcessGroup.terminate(pid, 2_000, leader_start: legacy, ps_env: ctx.far) in [
             :terminated,
             :killed
           ]

    refute os_pid_alive?(pid)
  end

  test "a leader recorded by its kernel-form start is recognised from another timezone", ctx do
    pid = live_leader!()
    started = Owner.start_id(pid)

    assert ProcessGroup.terminate(pid, 2_000, leader_start_id: started, ps_env: ctx.far) in [
             :terminated,
             :killed
           ]

    refute os_pid_alive?(pid)
  end

  test "a leader_start in no form this reads names no leader, and nothing raises" do
    pid = live_leader!()
    assert ProcessGroup.terminate(pid, 300, leader_start: 12_345) == :already_gone
    assert os_pid_alive?(pid)
  end

  test "a tree-file line naming a live pid with another start names nobody" do
    pid = live_leader!()
    # In the launcher's form on this kernel, its value changed: a pid reused by a stranger.
    assert ProcessGroup.recorded(tree_file!("reused-pid", "#{pid} #{tree_start(pid)}0")) == []
    assert ProcessGroup.recorded(tree_file!("same-pid", "#{pid} #{tree_start(pid)}")) == [pid]
  end
end
