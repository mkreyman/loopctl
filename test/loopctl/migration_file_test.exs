defmodule Loopctl.Test.MigrationFileTest do
  use ExUnit.Case, async: true

  alias Loopctl.Test.MigrationFile

  describe "load!/2" do
    @describetag :tmp_dir

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

      %{module: module, path: path, tmp_dir: tmp_dir}
    end

    test "requires the file when the module is not loaded", %{module: module, path: path} do
      assert MigrationFile.load!(module, path) == module
      assert module.x() == 1
    end

    test "reuses a copy the migrator compiled, without redefining it", ctx do
      # What Ecto.Migrator does with a pending migration in the test VM.
      Code.compile_file(ctx.path)

      {result, diagnostics} =
        Code.with_diagnostics(fn -> MigrationFile.load!(ctx.module, ctx.path) end)

      assert result == ctx.module
      refute Enum.any?(diagnostics, &(&1.message =~ "redefining module"))
    end

    test "refuses a loaded copy compiled from a different migration", ctx do
      # Another file defining the same module name, e.g. a migration renamed but not deleted.
      other = Path.join(ctx.tmp_dir, "2_other.exs")
      File.write!(other, "defmodule #{inspect(ctx.module)}, do: def(x, do: 2)")
      Code.compile_file(other)

      assert_raise ArgumentError, ~r/already loaded from/, fn ->
        MigrationFile.load!(ctx.module, ctx.path)
      end
    end

    test "reuses a copy compiled from the same migration at another path", ctx do
      # The migrator may compile through `_build/.../priv`: a symlink to `priv`, or a copy.
      copy = Path.join([ctx.tmp_dir, "build_priv", "1_probe.exs"])
      File.mkdir_p!(Path.dirname(copy))
      File.cp!(ctx.path, copy)
      Code.compile_file(copy)

      assert MigrationFile.load!(ctx.module, ctx.path) == ctx.module
    end

    test "refuses a loaded copy with no recorded source", ctx do
      {:ok, module, binary} =
        :compile.forms([{:attribute, 1, :module, ctx.module}], [:deterministic])

      {:module, ^module} = :code.load_binary(module, ~c"nofile", binary)

      assert_raise ArgumentError, ~r/no recorded source/, fn ->
        MigrationFile.load!(ctx.module, ctx.path)
      end
    end

    test "raises when the file does not define the module", %{path: path} do
      assert_raise ArgumentError, fn -> MigrationFile.load!(Loopctl.NoSuchMigration, path) end
    end
  end

  describe "file!/1" do
    @tag :tmp_dir
    test "resolves a version to its one migration file", %{tmp_dir: dir} do
      File.touch!(Path.join(dir, "7_a.exs"))
      File.touch!(Path.join(dir, "70_b.exs"))

      assert MigrationFile.file!(7, dir) == Path.join(dir, "7_a.exs")
    end

    @tag :tmp_dir
    test "raises when two files share the version", %{tmp_dir: dir} do
      File.touch!(Path.join(dir, "7_a.exs"))
      File.touch!(Path.join(dir, "7_b.exs"))

      assert_raise ArgumentError, ~r/expected one migration 7/, fn ->
        MigrationFile.file!(7, dir)
      end
    end

    @tag :tmp_dir
    test "raises a named error for a version with no file", %{tmp_dir: dir} do
      assert_raise ArgumentError, ~r/expected one migration 1/, fn ->
        MigrationFile.file!(1, dir)
      end
    end
  end
end
