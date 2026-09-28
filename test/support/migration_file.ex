defmodule Loopctl.Test.MigrationFile do
  @moduledoc """
  Loads a migration's module for a test, reusing it when something already loaded it.

  Migration modules are not compiled with the app, so a test that drives one loads the
  file itself. The module may already be loaded: on a fresh test database `mix test`'s
  alias runs `ecto.migrate` in the test VM, and `Ecto.Migrator` `Code.compile_file`s every
  pending migration (so does any other in-VM migrate, such as `mix do ecto.migrate + test`).
  An unconditional `Code.require_file` then redefines the module, and "redefining module"
  fails `--warnings-as-errors` after a green suite. The loaded copy was compiled from the
  same file, so reusing it is correct, whatever loaded it.
  """

  @doc "Returns `module`, requiring `file` only when `module` is not already loaded."
  @spec require!(module(), Path.t()) :: module()
  def require!(module, file) do
    unless Code.ensure_loaded?(module), do: Code.require_file(file)
    Code.ensure_loaded!(module)
  end
end
