defmodule Loopctl.ExitTag do
  @moduledoc """
  ONE bounded classification of a non-local exit / throw reason, for fail-soft guards.

  The rule ("log a stable, low-cardinality tag, NEVER the raw reason") had grown four
  private copies with two different behaviours, so the same wedged pool read as
  `RuntimeError` through one guard and `unknown`/`other` through another. Extracted so a
  guard gains a class by CALLING this, not by re-deriving the clause list.

  Why each clause is load-bearing:

    * `{reason, call}` — DBConnection reports a wedged or unstarted pool as
      `{:noproc, {DBConnection, :execute, []}}`, NOT as a bare `:noproc`, so an
      atom-only tagger degrades every REAL production exit.
    * `{{exception_or_atom, stacktrace}, call}` — crash PROPAGATION, when the called
      process dies of an exception rather than being absent. At least as common as
      `:noproc` for a supervised pool. Bounded either way: an atom, or the exception
      MODULE name — never its message, which carries host/database/role and query args.
  """

  @spec tag(term()) :: String.t()
  def tag(reason) when is_atom(reason), do: to_string(reason)

  # A BARE exception struct, not wrapped in an exit reason. `FairShare.over_cap?/4`'s rescue
  # branch hands one straight in, and without this clause it fell to the catch-all — so every
  # raise logged "unknown" and the class was lost at exactly the site that needed it. The
  # MODULE name only, never `Exception.message/1`, which on a Postgrex/DBConnection struct
  # names the backend host, database and role.
  def tag(%module{} = reason) when is_exception(reason), do: inspect(module)
  def tag({reason, _call}) when is_atom(reason), do: to_string(reason)
  def tag({{%module{}, _stack}, _call}), do: inspect(module)
  def tag({{reason, _stack}, _call}) when is_atom(reason), do: to_string(reason)
  def tag(_reason), do: "unknown"
end
