defmodule Mix.Tasks.Chg.Compile do
  @shortdoc "Compiles the project with its atoms preloaded, so two builds digest alike"
  @moduledoc """
  `mix compile ARGS` in a fresh VM that makes the project's atoms first, in one order
  (`ChgAdapter.Atoms`), so two builds of one commit lay out their modules alike and
  coverage selection does not count a module altered for how a build happened to run.
  Dependencies compile first, in this VM, so their atoms are on the list.

  Every compile chg's adapter runs goes through here: `chg.static`'s, the snapshot's,
  and the one `chg.affected`, `chg.refs` and a recording run start with. Its output and
  exit status are the compile's.

      mix chg.compile --warnings-as-errors
  """
  use Mix.Task

  @impl true
  def run(args) do
    # Compiling the dependencies prunes the code path to the project's, which drops this
    # archive's ebin: load its modules first.
    ChgAdapter.preload!()
    Mix.Task.run("deps.loadpaths")

    {_, status} =
      System.cmd("mix", ["compile" | args],
        env: ChgAdapter.Atoms.env(),
        into: IO.stream(:stdio, :line),
        stderr_to_stdout: true
      )

    ChgAdapter.halt(status)
  end
end
