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

    test "refuses a loaded copy compiled from a different file", ctx do
      other = Path.join(ctx.tmp_dir, "2_other.exs")
      File.cp!(ctx.path, other)
      Code.compile_file(other)

      assert_raise ArgumentError, ~r/already loaded from/, fn ->
        MigrationFile.load!(ctx.module, ctx.path)
      end
    end

    test "raises when the file does not define the module", %{path: path} do
      assert_raise ArgumentError, fn -> MigrationFile.load!(Loopctl.NoSuchMigration, path) end
    end
  end

  describe "file!/1" do
    test "resolves a version to its one migration file" do
      assert MigrationFile.file!(20_260_927_120_000) ==
               Path.expand("priv/repo/migrations/20260927120000_add_thread_page.exs")
    end

    @tag :tmp_dir
    test "raises when two files share the version", %{tmp_dir: dir} do
      File.touch!(Path.join(dir, "7_a.exs"))
      File.touch!(Path.join(dir, "7_b.exs"))

      assert_raise ArgumentError, ~r/expected one migration 7/, fn ->
        MigrationFile.file!(7, dir)
      end
    end

    test "raises a named error for a version with no file" do
      assert_raise ArgumentError, ~r/expected one migration 1/, fn -> MigrationFile.file!(1) end
    end
  end

  describe "the guard" do
    # A test that names a migration module must load it through require!/2: a bare load
    # redefines the migrator's copy on a fresh database, and no load at all passes only on
    # a fresh database, where the migrator happened to load it.
    @loaders ["Code.require_file", "Code.compile_file", "Code.eval_file"]

    defp violation?(source) do
      source =~ ~r/Loopctl\.Repo\.Migrations\b/ and
        (not (source =~ "MigrationFile.require!(") or
           Enum.any?(@loaders, &String.contains?(source, &1)))
    end

    test "recognises each way in, and the sanctioned one" do
      assert violation?("alias Loopctl.Repo.Migrations.AddX\nCode.require_file(f)")
      assert violation?("alias Loopctl.Repo.Migrations.AddX\nCode.compile_file(f)")
      assert violation?("x = &Code.eval_file/1\nLoopctl.Repo.Migrations.AddX.up()")
      assert violation?("Loopctl.Repo.Migrations.AddX.backfill_sql()")
      # A loader is refused even beside a sanctioned call.
      assert violation?(
               "MigrationFile.require!(AddX, 1)\nCode.eval_file(f)\nLoopctl.Repo.Migrations"
             )

      refute violation?("alias Loopctl.Repo.Migrations.AddX\nMigrationFile.require!(AddX, 1)")
      assert violation?("Module.concat(Loopctl.Repo.Migrations, \"AddX\").up()")
      refute violation?("Code.require_file(\"config/worktree_partition.exs\")")
    end

    test "every test that names a migration module loads it through require!/2" do
      sources =
        for file <- Path.wildcard("test/**/*.exs") -- [Path.relative_to_cwd(__ENV__.file)],
            do: {file, File.read!(file)}

      assert for({file, source} <- sources, violation?(source), do: file) == []

      # Non-vacuous: the scan reached the call sites it exists to police.
      assert Enum.count(sources, fn {_, source} -> source =~ "MigrationFile.require!(" end) > 1
    end
  end
end
