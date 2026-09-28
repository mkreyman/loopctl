defmodule Loopctl.Test.MigrationFileTest do
  use ExUnit.Case, async: true

  alias Loopctl.Test.MigrationFile

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    module =
      Module.concat([Loopctl.Repo.Migrations, "Probe#{System.unique_integer([:positive])}"])

    path = Path.join(tmp_dir, "1_probe.exs")
    File.write!(path, "defmodule #{inspect(module)}, do: def(x, do: 1)")

    on_exit(fn ->
      :code.purge(module)
      :code.delete(module)
      :code.purge(module)
    end)

    %{module: module, path: path}
  end

  test "requires the file when the module is not loaded", %{module: module, path: path} do
    assert MigrationFile.require!(module, path) == module
    assert module.x() == 1
  end

  test "reuses a copy the migrator compiled, without redefining it", ctx do
    # What Ecto.Migrator does with a pending migration in the test VM.
    Code.compile_file(ctx.path)

    {result, diagnostics} =
      Code.with_diagnostics(fn -> MigrationFile.require!(ctx.module, ctx.path) end)

    assert result == ctx.module
    refute Enum.any?(diagnostics, &(&1.message =~ "redefining module"))
  end

  test "raises when the file does not define the module", %{path: path} do
    assert_raise ArgumentError, fn -> MigrationFile.require!(Loopctl.NoSuchMigration, path) end
  end

  test "every test that loads a migration goes through require!/2" do
    files = Path.wildcard("test/**/*.exs") -- [Path.relative_to_cwd(__ENV__.file)]

    bare =
      for file <- files,
          source = File.read!(file),
          source =~ "Code.require_file(" and source =~ "migrations",
          do: file

    guarded = Enum.filter(files, &(File.read!(&1) =~ "MigrationFile.require!("))

    assert bare == []
    # Non-vacuous: the scan found the call sites it exists to police.
    assert length(guarded) > 1
  end
end
