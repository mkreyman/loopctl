defmodule Loopctl.Test.MigrationModules do
  @moduledoc """
  Unloads modules compiled from migration files, so a test that `Code.require_file`s a
  migration defines its module for the first time.

  `mix test` runs `ecto.migrate` in the test VM (the `test` alias in `mix.exs`). On a
  database with pending migrations, `Ecto.Migrator` loads each pending file with
  `Code.compile_file/1`, which leaves every module the file defines loaded. A migration
  test that then requires the same file redefines those modules, and the warning fails
  `--warnings-as-errors` after a green suite. CI's test job migrates in a separate step
  first, so it never takes that path; a fresh local database (a new worktree) does.

  Matching on each module's compiled `source`, not on a name prefix, catches every module
  a migration file defines, helpers included, and never a `lib/` module that happens to
  share the namespace.
  """

  @migrations_dir Path.expand("priv/repo/migrations")

  @doc "Purges and deletes every loaded module whose source file lies under `dir`."
  @spec unload_compiled_from(Path.t()) :: [module()]
  def unload_compiled_from(dir \\ @migrations_dir) do
    prefix = Path.expand(dir) <> "/"

    for {module, _} <- :code.all_loaded(), compiled_under?(module, prefix) do
      :code.purge(module)
      :code.delete(module)
      module
    end
  end

  defp compiled_under?(module, prefix) do
    case module.module_info(:compile)[:source] do
      nil -> false
      source -> String.starts_with?(to_string(source), prefix)
    end
  end
end
