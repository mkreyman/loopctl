defmodule Loopctl.Test.MigrationModulesTest do
  use ExUnit.Case, async: true

  alias Loopctl.Test.MigrationModules

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    suffix = System.unique_integer([:positive])
    migration = Module.concat([Loopctl.Repo.Migrations, "Probe#{suffix}"])
    helper = Module.concat([Loopctl.MigrationProbeHelper, "H#{suffix}"])
    file = Path.join(tmp_dir, "1_probe.exs")

    File.write!(file, """
    defmodule #{inspect(migration)}, do: def(x, do: 1)
    defmodule #{inspect(helper)}, do: def(x, do: 1)
    """)

    on_exit(fn -> MigrationModules.unload([file]) end)

    %{probe_file: file, migration: migration, helper: helper}
  end

  test "unloads every module a file defines, helpers included, leaving no old code", ctx do
    Code.compile_file(ctx.probe_file)

    assert Enum.sort([ctx.migration, ctx.helper]) ==
             Enum.sort(MigrationModules.unload([ctx.probe_file]))

    for module <- [ctx.migration, ctx.helper] do
      refute :erlang.module_loaded(module)
      refute :erlang.check_old_code(module)
    end

    # The failure this exists for: compiling the same file again must not redefine. Only
    # this compile's diagnostics, not the VM-global stderr other async tests write to.
    {_, diagnostics} = Code.with_diagnostics(fn -> Code.compile_file(ctx.probe_file) end)
    refute Enum.any?(diagnostics, &(&1.message =~ "redefining module"))
  end

  test "unloads a module that already has old code", ctx do
    Code.with_diagnostics(fn ->
      Code.compile_file(ctx.probe_file)
      Code.compile_file(ctx.probe_file)
    end)

    assert :erlang.check_old_code(ctx.migration)

    MigrationModules.unload([ctx.probe_file])

    refute :erlang.module_loaded(ctx.migration)
    refute :erlang.check_old_code(ctx.migration)
  end

  test "leaves a module no file names loaded", ctx do
    assert [] == MigrationModules.unload([ctx.probe_file])
    assert :erlang.module_loaded(__MODULE__)
  end

  test "reads the migrations from the directory Ecto.Migrator uses" do
    dir = Ecto.Migrator.migrations_path(Loopctl.Repo)
    files = MigrationModules.migration_files()

    assert files != []
    assert Enum.all?(files, &(Path.dirname(&1) == dir and Path.extname(&1) == ".exs"))
  end

  test "test_helper.exs unloads the migrator's copies before ExUnit starts" do
    helper = File.read!("test/test_helper.exs")

    assert [before_start, _] = Regex.split(~r/ExUnit\.start\(/, helper, parts: 2)
    assert before_start =~ ~r/^Loopctl\.Test\.MigrationModules\.unload_migrator_copies\(\)$/m
  end
end
