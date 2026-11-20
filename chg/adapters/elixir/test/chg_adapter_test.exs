defmodule ChgAdapterTest do
  use ExUnit.Case, async: true

  import ChgAdapter, only: [dep_env: 2]

  describe "sync_deps/3" do
    setup do
      dir = Path.join(System.tmp_dir!(), "chg-sync-deps-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(dir) end)
      # The deps directory does not exist yet, as in a project without deps.
      %{marker: Path.join([dir, "deps", ".chg_lock"])}
    end

    test "a marker holding the lock's digest fetches nothing", %{marker: marker} do
      ChgAdapter.record_lock(marker, "abc")
      assert ChgAdapter.sync_deps(marker, fn -> "abc" end, fn -> flunk("fetched") end) == :ok
    end

    test "a missing or stale marker fetches, then records the lock as the fetch left it",
         %{marker: marker} do
      lock = :counters.new(1, [])
      digest = fn -> "lock-#{:counters.get(lock, 1)}" end
      fetch = fn -> {:counters.add(lock, 1, 1), 0} end

      assert ChgAdapter.sync_deps(marker, digest, fetch) == :ok
      assert File.read!(marker) == "lock-1"
      assert ChgAdapter.sync_deps(marker, digest, fn -> flunk("fetched again") end) == :ok
    end

    test "a failed fetch returns its output and records nothing", %{marker: marker} do
      assert ChgAdapter.sync_deps(marker, fn -> "abc" end, fn -> {"no hex", 1} end) ==
               {:error, "no hex"}

      refute File.exists?(marker)
    end
  end

  test "a dependency's tasks run in test unless :only leaves test out" do
    assert dep_env(:credo, [{:credo, "~> 1.7"}]) == "test"
    assert dep_env(:credo, [{:credo, "~> 1.7", only: [:dev, :test], runtime: false}]) == "test"
    assert dep_env(:dialyxir, [{:dialyxir, "~> 1.4", only: :dev, runtime: false}]) == "dev"
    assert dep_env(:dialyxir, [{:dialyxir, path: "../dialyxir", only: :ci}]) == "ci"
    assert dep_env(:dialyxir, [{:dialyxir, path: "../dialyxir"}]) == "test"
  end

  test "a missing dependency has no env" do
    assert dep_env(:dialyxir, [{:credo, "~> 1.7"}]) == nil
  end
end
