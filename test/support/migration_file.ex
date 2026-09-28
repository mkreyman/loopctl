defmodule Loopctl.Test.MigrationFile do
  @moduledoc """
  Loads a migration file into a test that drives its `up`/`down` directly, WITHOUT redefining
  a module already in memory.

  `mix test` runs `ecto.migrate` in the same VM first (the `test` alias in mix.exs). On a FRESH
  test database — a new worktree, a new CI runner — every migration is pending, so the migrator
  loads every migration module; a test that then `Code.require_file`s the same file redefines
  the module, and `--warnings-as-errors` turns the "redefining module" warning into a failed
  gate after the whole suite passed. On an already-migrated database nothing is loaded, which is
  why it looked intermittent.

  A migration file defines exactly one module; when it is already loaded, the file is not
  compiled again.
  """

  @doc "Requires `path` unless the module it defines is already loaded."
  @spec require!(Path.t()) :: :ok
  def require!(path) do
    case Regex.run(~r/^defmodule\s+([\w.]+)\s+do/m, File.read!(path)) do
      [_, name] ->
        module = Module.concat([name])
        unless Code.ensure_loaded?(module), do: Code.require_file(path)
        :ok

      nil ->
        raise ArgumentError, "#{path} defines no module"
    end
  end
end
