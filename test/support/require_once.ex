defmodule Loopctl.Test.RequireOnce do
  @moduledoc """
  Requires a source file that is NOT compiled with the app — a migration under
  `priv/repo/migrations`, `config/worktree_partition.exs` — WITHOUT redefining a module already
  in memory.

  Such a file may already have been loaded by something that does not mark it required:
  `mix test` runs `ecto.migrate` in the same VM first (the `test` alias), and on a FRESH test
  database — a new worktree, a new CI runner — every migration is pending, so the migrator
  `Code.compile_file`s every migration module; `config/test.exs` requires the partition file at
  boot. A later `Code.require_file` compiles it again and warns "redefining module", which
  `--warnings-as-errors` turns into a failed gate AFTER the whole suite passed. On an
  already-migrated database nothing is loaded first, which is why it looked intermittent.

  `test/loopctl/require_once_guard_test.exs` fails on any direct `Code.require_file` under
  `test/`, so this stays the only way in.
  """

  @doc """
  Requires `path` unless the ONE module it defines is already loaded, and returns that module.
  Raises when the file does not define exactly one top-level module: the check reads the
  module's name from the file, so a second module would make it check the wrong one.
  """
  @spec require!(Path.t()) :: module()
  def require!(path) do
    module = defined_module!(path)
    unless Code.ensure_loaded?(module), do: Code.require_file(path)
    module
  end

  defp defined_module!(path) do
    quoted = path |> File.read!() |> Code.string_to_quoted!()

    top_level =
      case quoted do
        {:__block__, _, forms} -> forms
        form -> [form]
      end

    case for({:defmodule, _, [alias_ast | _]} <- top_level, do: Macro.expand(alias_ast, __ENV__)) do
      [module] -> module
      found -> raise ArgumentError, "#{path} defines #{length(found)} top-level modules, not one"
    end
  end
end
