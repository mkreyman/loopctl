defmodule Loopctl.Test.MigrationFile do
  @moduledoc """
  Loads a migration's module for a test, reusing it when the same file already loaded it.

  Migration modules are not compiled with the app, so a test that drives one loads the
  file itself. The module may already be loaded: on a fresh test database `mix test`'s
  alias runs `ecto.migrate` in the test VM, and `Ecto.Migrator` `Code.compile_file`s every
  pending migration (so does any other in-VM migrate, such as `mix do ecto.migrate + test`).
  An unconditional `Code.require_file` then redefines the module, and "redefining module"
  fails `--warnings-as-errors` after a green suite.

  Every test that names a `Loopctl.Repo.Migrations` module loads it through `require!/2`,
  so the module is present whatever state the database was in; the guard in
  `Loopctl.Test.MigrationFileTest` refuses any other way in.
  """

  @doc """
  Returns `module`, the migration with `version`, loading its file only when `module` is
  not already loaded. Raises when no single file has that version, when the file does not
  define `module`, or when the loaded `module` was compiled from a different file.
  """
  @spec require!(module(), pos_integer()) :: module()
  def require!(module, version), do: load!(module, file!(version))

  @doc "Returns `module`, loading `file` only when `module` is not already loaded."
  @spec load!(module(), Path.t()) :: module()
  def load!(module, file) do
    file = Path.expand(file)

    if Code.ensure_loaded?(module) do
      same_source!(module, file)
    else
      Code.require_file(file)
    end

    Code.ensure_loaded!(module)
  end

  @doc "The one migration file with `version` in `dir` (default: the directory `mix ecto.migrate` reads)."
  @spec file!(pos_integer(), Path.t()) :: Path.t()
  def file!(version, dir \\ Path.expand("priv/repo/migrations", File.cwd!())) do
    case Path.wildcard(Path.join(dir, "#{version}_*.exs")) do
      [file] ->
        file

      files ->
        raise ArgumentError,
              "expected one migration #{version} in #{dir}, found #{inspect(files)}"
    end
  end

  defp same_source!(module, file) do
    source = module.module_info(:compile)[:source]

    if source && Path.expand(to_string(source)) != file do
      raise ArgumentError,
            "#{inspect(module)} is already loaded from #{source}, not from #{file}"
    end
  end
end
