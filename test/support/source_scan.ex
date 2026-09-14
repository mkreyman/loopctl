defmodule Loopctl.SourceScan do
  @moduledoc """
  Finds CALLS to a named function in source files, by parsing rather than by matching text.

  Two drift guards in this repo bind a declaration to the modules that actually enforce a gate
  — `Loopctl.Custody.ContextSurfaceTest` for the custody halt and
  `Loopctl.Tenants.TierCapabilitiesTest` for the human anchor on the context side. Both scan
  `lib/loopctl/**`, because the gates they check have no route and a router walk cannot see
  them.

  **They used to match raw file text, and a `#` comment satisfied them** (#833 round 3). A
  module declared as enforcing a gate that only MENTIONED it in a comment, a moduledoc or a
  string passed — in the direction those guards' own failure messages call the dangerous one.
  That is the same species as every other defect this repo has found in its own checks: a
  check satisfied by the appearance of the thing rather than the thing.

  `Code.string_to_quoted!/1` cannot produce a call node from a comment or a string literal, so
  matching on the AST closes it exactly rather than approximately.

  ## What it still cannot see

  A call reached through an alias of a DIFFERENT name (`alias Loopctl.Runners, as: R`, then
  `R.custody_halted?(...)`), one built by a macro, and `apply/3`. It matches the module's LAST
  alias segment, so both `Runners.f()` and `Loopctl.Runners.f()` count; a renamed alias does
  not. Say so wherever it is used rather than implying the scan is total.
  """

  @doc """
  Module names (as strings, from each file's `defmodule`) that CALL `module.function` — where
  `module` is matched on its last alias segment, so `Runners.f()` and `Loopctl.Runners.f()`
  both count.

  Unparseable files raise: a file this cannot read is a file the guard cannot vouch for, and
  silently skipping it is how a scan starts passing for the wrong reason.
  """
  @spec callers(String.t(), atom(), atom()) :: [String.t()]
  def callers(glob, module, function) when is_atom(module) and is_atom(function) do
    glob
    |> Path.wildcard()
    |> Enum.filter(&calls?(&1, module, function))
    |> Enum.map(&defmodule_name!/1)
  end

  @doc "True when `path` contains a call to `module.function`, at any arity."
  @spec calls?(String.t(), atom(), atom()) :: boolean()
  def calls?(path, module, function) do
    path
    |> File.read!()
    |> Code.string_to_quoted!()
    |> Macro.prewalk(false, fn node, found -> {node, found or call?(node, module, function)} end)
    |> elem(1)
  end

  @doc "The module name a file declares, as a string."
  @spec defmodule_name!(String.t()) :: String.t()
  def defmodule_name!(path) do
    path
    |> File.read!()
    |> Code.string_to_quoted!()
    |> Macro.prewalk(nil, fn
      {:defmodule, _, [{:__aliases__, _, segments} | _]} = node, nil ->
        {node, Enum.map_join(segments, ".", &Atom.to_string/1)}

      node, acc ->
        {node, acc}
    end)
    |> elem(1)
    |> case do
      nil -> raise "no defmodule found in #{path}"
      name -> name
    end
  end

  # `Module.function(...)` — the alias's LAST segment is compared, so a fully qualified call and
  # a call through `alias` both match.
  defp call?({{:., _, [{:__aliases__, _, segments}, function]}, _, _args}, module, function) do
    List.last(segments) == module
  end

  defp call?(_node, _module, _function), do: false
end
