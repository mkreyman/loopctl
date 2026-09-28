defmodule Loopctl.Test.MigrationModulesTest do
  use ExUnit.Case, async: true

  alias Loopctl.Test.MigrationModules

  @moduletag :tmp_dir

  test "unloads every module a file under the directory defines, helpers included", %{
    tmp_dir: tmp_dir
  } do
    dir = Path.join(tmp_dir, "migrations")
    File.mkdir_p!(dir)
    suffix = System.unique_integer([:positive])
    migration = Module.concat([Loopctl.Repo.Migrations, "Probe#{suffix}"])
    helper = Module.concat([Loopctl.MigrationProbeHelper, "H#{suffix}"])
    outside = Module.concat([Loopctl.Repo.Migrations, "Outside#{suffix}"])

    on_exit(fn ->
      for module <- [migration, helper, outside] do
        :code.delete(module)
        :code.purge(module)
      end
    end)

    file = Path.join(dir, "1_probe.exs")

    File.write!(file, """
    defmodule #{inspect(migration)}, do: def(x, do: 1)
    defmodule #{inspect(helper)}, do: def(x, do: 1)
    """)

    other = Path.join(tmp_dir, "outside.exs")
    File.write!(other, "defmodule #{inspect(outside)}, do: def(x, do: 1)")

    Code.compile_file(file)
    Code.compile_file(other)

    unloaded = MigrationModules.unload_compiled_from(dir)

    assert Enum.sort([migration, helper]) == Enum.sort(unloaded)
    refute :code.is_loaded(migration)
    refute :code.is_loaded(helper)
    refute :erlang.check_old_code(migration)
    assert {:file, _} = :code.is_loaded(outside)

    # The failure this exists for: compiling the same file again must not redefine. Only
    # this compile's diagnostics, not the VM-global stderr other async tests write to.
    {_, diagnostics} = Code.with_diagnostics(fn -> Code.compile_file(file) end)
    refute Enum.any?(diagnostics, &(&1.message =~ "redefining module"))
  end

  test "the default directory is the one holding this repo's migrations" do
    dir = MigrationModules.migrations_dir()

    assert Path.type(dir) == :absolute
    assert File.exists?(Path.join(dir, "20260927120000_add_thread_page.exs"))
  end

  test "test_helper.exs unloads the migrations directory before ExUnit starts" do
    helper = File.read!("test/test_helper.exs")

    assert [before_start, _] = Regex.split(~r/ExUnit\.start\(/, helper, parts: 2)
    assert before_start =~ ~r/^Loopctl\.Test\.MigrationModules\.unload_compiled_from\(\)$/m
  end
end
