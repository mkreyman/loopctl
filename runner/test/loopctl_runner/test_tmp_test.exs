defmodule LoopctlRunner.TestTmpTest do
  use ExUnit.Case, async: true

  alias LoopctlRunner.{Owner, TestTmp}
  import LoopctlRunner.TestSupport

  # Every root here is under a base of the test's own, never the real temp directory.
  setup do
    {:ok, base: tmp_dir!("tmp-sweep")}
  end

  defp root!(base, name, owner) do
    root = Path.join(base, "loopctl-runner-suite-#{name}")
    File.mkdir_p!(root)
    if owner, do: File.write!(Path.join(root, "owner.json"), JSON.encode!(owner))
    root
  end

  defp aged!(path), do: File.touch!(path, System.os_time(:second) - 7_200) && path

  test "a root whose BEAM is gone is swept, and a live one is kept", %{base: base} do
    {:ok, me} = Owner.current()
    {dead_pid, 0} = System.cmd("sh", ["-c", "echo $$"])
    dead = Map.put(me, "beam_os_pid", dead_pid |> String.trim() |> String.to_integer())

    gone = root!(base, "gone", dead)
    live = root!(base, "live", me)

    assert TestTmp.sweep_stale(base) == [gone]
    refute File.exists?(gone)
    assert File.exists?(live)
  end

  test "a root that never recorded an owner is judged by the pid in its name, never its age",
       %{base: base} do
    # A pid no system hands out, so it can never be reused into a live one mid-test.
    gone = aged!(root!(base, "999999999", nil))
    # Old, and ownerless, but its pid still runs: a live suite, however long it has run.
    live = aged!(root!(base, System.pid(), nil))

    assert TestTmp.sweep_stale(base) == [gone]
    assert File.exists?(live)
  end

  test "what suites before roots left is swept once old, a fresh one kept", %{base: base} do
    old =
      for name <- ~w(loopctl-runner-test-a-1 loopctl-runner-stragglers-x loopctl-runner-sweep-y) do
        path = Path.join(base, name)
        File.write!(path, "")
        aged!(path)
      end

    fresh = Path.join(base, "loopctl-runner-test-fresh-2")
    File.mkdir_p!(fresh)

    assert Enum.sort(TestTmp.sweep_stale(base)) == Enum.sort(old)
    assert File.exists?(fresh)
  end

  test "a symlink at the root's path is refused, not written through", %{base: base} do
    target = Path.join(base, "elsewhere")
    File.mkdir_p!(target)
    File.ln_s!(target, TestTmp.root(base))

    assert_raise RuntimeError, ~r/not this user's directory/, fn -> TestTmp.arm(base) end
    refute File.exists?(Path.join(target, "owner.json"))
  end

  test "a stale entry the sweep cannot remove is said, not dropped", %{base: base} do
    stuck = root!(base, "999999999", nil)
    File.mkdir_p!(Path.join(stuck, "held"))
    File.chmod!(stuck, 0o500)
    on_exit(fn -> File.chmod(stuck, 0o700) end)

    said = ExUnit.CaptureIO.capture_io(:stderr, fn -> assert TestTmp.sweep_stale(base) == [] end)
    assert said =~ "could not sweep #{stuck}"
  end

  test "arm makes a private root that records its owner, and the suite's end removes it",
       %{base: base} do
    :ok = TestTmp.arm(base)
    root = TestTmp.root(base)

    assert %File.Stat{mode: mode} = File.stat!(root)
    assert Bitwise.band(mode, 0o777) == 0o700
    {:ok, me} = Owner.current()
    assert root |> Path.join("owner.json") |> File.read!() |> JSON.decode!() == me

    :ok = TestTmp.sweep_suite(%{}, base)
    refute File.exists?(root)
  end

  test "each directory asked for is new and inside this BEAM's root" do
    one = TestTmp.dir!("same")
    two = TestTmp.dir!("same")

    assert one != two
    assert Path.dirname(one) == TestTmp.root()
    assert File.dir?(one) and File.dir?(two)
  end
end
