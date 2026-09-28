defmodule Loopctl.Test.MigrationModules do
  @moduledoc """
  Unloads the modules `mix ecto.migrate` compiled into the test VM, so a test that
  `Code.require_file`s a migration defines its module for the first time.

  `mix test` runs `ecto.migrate` in the test VM (the `test` alias in `mix.exs`). On a
  database with pending migrations, `Ecto.Migrator` loads each pending file with
  `Code.compile_file/1`, which leaves every module the file defines loaded. A migration
  test that then requires the same file redefines those modules, and the warning fails
  `--warnings-as-errors` after a green suite. CI's test job migrates in a separate step
  first, so it never takes that path; a fresh local database (a new worktree) does.

  The modules to unload are read from the migration files themselves, so nothing depends
  on how a loaded module records where it came from.
  """

  @namespace "Elixir.Loopctl.Repo.Migrations."

  @doc """
  Unloads the modules every migration file defines, when the migrator has loaded any.

  Every migration defines a module under `Loopctl.Repo.Migrations`, so when none is
  loaded (an already-migrated database) the files are not read at all.
  """
  @spec unload_migrator_copies() :: [module()]
  def unload_migrator_copies do
    if Enum.any?(:code.all_loaded(), fn {module, _} -> in_namespace?(module) end),
      do: unload(migration_files()),
      else: []
  end

  @doc "The migration files, from the directory `Ecto.Migrator` reads."
  @spec migration_files() :: [Path.t()]
  def migration_files do
    Loopctl.Repo |> Ecto.Migrator.migrations_path() |> Path.join("*.exs") |> Path.wildcard()
  end

  @doc "Unloads every loaded module that one of `files` defines; returns those modules."
  @spec unload([Path.t()]) :: [module()]
  def unload(files) do
    for file <- files, module <- defined_modules(file), :erlang.module_loaded(module) do
      # purge drops any old code (without it delete refuses and changes nothing), delete
      # makes the current code old, and the second purge removes that.
      :code.purge(module)
      :code.delete(module)
      :code.purge(module)
      module
    end
  end

  defp defined_modules(file) do
    {_, modules} =
      file
      |> File.read!()
      |> Code.string_to_quoted!()
      |> Macro.prewalk([], fn
        {:defmodule, _, [{:__aliases__, _, parts} | _]} = node, acc ->
          {node, [Module.concat(parts) | acc]}

        node, acc ->
          {node, acc}
      end)

    modules
  end

  defp in_namespace?(module), do: String.starts_with?(Atom.to_string(module), @namespace)
end
