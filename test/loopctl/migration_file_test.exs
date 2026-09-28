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

    test "reuses a copy compiled through a symlinked directory", ctx do
      # The migrator may compile through `_build/.../priv`, a symlink to `priv`.
      link = Path.join(ctx.tmp_dir, "linked")
      File.ln_s!(ctx.tmp_dir, link)
      Code.compile_file(Path.join(link, "1_probe.exs"))

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

    test "raises a named error for a version with no file" do
      assert_raise ArgumentError, ~r/expected one migration 1/, fn ->
        MigrationFile.file!(1, System.tmp_dir!())
      end
    end
  end

  describe "the guard" do
    # Every migration module a test names must have its own require!/2: a bare load
    # redefines the migrator's copy on a fresh database, and no load at all passes only on
    # a fresh database, where the migrator happened to load it.
    @bare_load ~r/Code\.(require_file|compile_file|eval_file)\([^)\n]*[Mm]igration/
    @named ~r/Loopctl\.Repo\.Migrations\.(\w+)|Module\.concat\(Loopctl\.Repo\.Migrations,\s*"(\w+)"\)/

    defp violations(source) do
      named =
        @named
        |> Regex.scan(source, capture: :all_but_first)
        |> Enum.map(&Enum.find(&1, fn name -> name != "" end))
        |> Enum.uniq()

      unloaded = Enum.reject(named, &(source =~ "MigrationFile.require!(#{&1},"))
      if source =~ @bare_load, do: [:bare_load | unloaded], else: unloaded
    end

    test "recognises each way in, and the sanctioned one" do
      assert violations("Code.compile_file(\"priv/repo/migrations/1_x.exs\")") == [:bare_load]

      assert violations("""
             alias Loopctl.Repo.Migrations.AddX
             MigrationFile.require!(AddX, 1)
             Code.eval_file(MigrationFile.file!(1))
             """) == [:bare_load]

      assert violations("""
             alias Loopctl.Repo.Migrations.AddX
             alias Loopctl.Repo.Migrations.AddY
             MigrationFile.require!(AddX, 1)
             AddY.up()
             """) == ["AddY"]

      assert violations(~s|Module.concat(Loopctl.Repo.Migrations, "AddX").up()|) == ["AddX"]

      assert violations("""
             alias Loopctl.Repo.Migrations.AddX
             MigrationFile.require!(AddX, 1)
             Code.require_file(@check_path)
             """) == []
    end

    test "every migration module a test names is loaded through require!/2" do
      sources =
        for file <- Path.wildcard("test/**/*.exs") -- [Path.relative_to_cwd(__ENV__.file)],
            do: {file, File.read!(file)}

      assert for({file, source} <- sources, (v = violations(source)) != [], do: {file, v}) == []

      # Non-vacuous: the scan reached the call sites it exists to police.
      assert Enum.count(sources, fn {_, source} -> source =~ @named end) > 1
    end
  end
end
