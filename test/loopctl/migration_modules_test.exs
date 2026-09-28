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
    assert {:file, _} = :code.is_loaded(outside)

    # The failure this exists for: compiling the same file again must not redefine.
    warnings = ExUnit.CaptureIO.capture_io(:stderr, fn -> Code.compile_file(file) end)
    refute warnings =~ "redefining module"
  end

  test "test_helper.exs unloads the migrations directory before ExUnit starts" do
    helper = File.read!("test/test_helper.exs")
    [before_start | _] = String.split(helper, "ExUnit.start()", parts: 2)

    assert before_start =~ ~r/^Loopctl\.Test\.MigrationModules\.unload_compiled_from\(\)$/m
  end
end
