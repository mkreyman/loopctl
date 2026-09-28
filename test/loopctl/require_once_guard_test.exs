defmodule Loopctl.RequireOnceGuardTest do
  @moduledoc """
  `Loopctl.Test.RequireOnce` only helps if nothing goes around it: a direct `Code.require_file`
  of a file something else already loaded redefines its module, and the gate's
  `--warnings-as-errors` fails AFTER the suite passed, and only on a fresh test database. This
  also covers the helper's own two branches.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Loopctl.Test.RequireOnce

  test "no test requires or compiles a source file except through RequireOnce" do
    offenders =
      "test/**/*.{ex,exs}"
      |> Path.wildcard()
      |> Enum.reject(
        &(&1 in ["test/support/require_once.ex", __ENV__.file |> Path.relative_to_cwd()])
      )
      |> Enum.filter(&(File.read!(&1) =~ ~r/Code\.(require_file|compile_file|load_file)\(/))

    assert offenders == []
  end

  @tag :tmp_dir
  test "a module a migrator already compiled is not redefined, and is returned", %{tmp_dir: dir} do
    name = "RequireOnceProbe#{System.unique_integer([:positive])}"
    path = Path.join(dir, "probe.exs")
    File.write!(path, "defmodule Loopctl.Test.#{name} do\n  def up, do: :ok\nend\n")

    # What `Ecto.Migrator` does on a fresh database: compile, without marking it required.
    Code.compile_file(path)

    stderr = capture_io(:stderr, fn -> send(self(), {:module, RequireOnce.require!(path)}) end)

    refute stderr =~ "redefining module"
    assert_received {:module, module}
    assert module == Module.concat(Loopctl.Test, name)
  end

  @tag :tmp_dir
  test "a file defining two modules is refused, not half-checked", %{tmp_dir: dir} do
    path = Path.join(dir, "two.exs")

    File.write!(
      path,
      "defmodule A1#{System.unique_integer([:positive])} do end\ndefmodule B1 do end\n"
    )

    assert_raise ArgumentError, ~r/2 top-level modules/, fn -> RequireOnce.require!(path) end
  end
end
