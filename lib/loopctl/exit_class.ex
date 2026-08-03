defmodule Loopctl.ExitClass do
  @moduledoc """
  The BOUNDED, kind-prefixed metric CLASS for a non-local exit / throw.

  `Loopctl.ExitTag` answers "what was the reason", open-endedly: ANY exit-reason atom or
  exception MODULE name. Right for a log line, wrong for a Prometheus LABEL — `error_class`
  multiplies `tenant_id` (`ScaleMetrics.degraded_read_tags/1`), so verbatim it is unbounded.

  So the tag is collapsed onto a CLOSED set: the shapes an operator actually triages —
  an absent pool (`noproc`), a wedged one (`timeout`), one shutting down (`shutdown`) or
  killed (`killed`), plus the two exception MODULES a pooled process actually dies of
  (`Postgrex.Error`, `DBConnection.ConnectionError`) — and `other` for everything else.
  The crash-PROPAGATION shapes are ENUMERATED rather than collapsed because `ExitTag`'s
  clause list exists precisely to stop them degrading to a catch-all, and the kind prefix
  stays because a dead pool and a throw escaping a guard are different investigations.

  That set is a METRICS vocabulary: derived from the exit REASON, it cannot say WHICH process
  died, so a caller deciding RETRYABILITY must ask `pool_exit?/1` instead.

  Extracted rather than copied into each guard for the same reason `ExitTag` itself was:
  four private copies of "classify this exit" had already diverged.
  """

  alias Loopctl.ExitTag

  @tags ~w(noproc timeout shutdown killed Postgrex.Error DBConnection.ConnectionError)

  @doc """
  Bound an already-`ExitTag`-tagged reason to `"<kind>:<tag>"` over the closed tag set.
  """
  @spec bounded(:exit | :throw, String.t()) :: String.t()
  def bounded(kind, tag) when kind in [:exit, :throw] and is_binary(tag),
    do: "#{kind}:#{closed(tag)}"

  @doc "Tag a raw exit/throw reason and bound it in one step."
  @spec classify(:exit | :throw, term()) :: String.t()
  def classify(kind, reason), do: bounded(kind, ExitTag.tag(reason))

  @pool_modules [DBConnection, DBConnection.Holder, DBConnection.Ownership, Postgrex]

  @doc """
  Whether an EXIT `reason` is DEMONSTRABLY from the DB pool: its call element names a pool
  module, as in `{:noproc, {DBConnection, :execute, []}}` (the crash-propagation shape
  `{{exception, stack}, {DBConnection, ...}}` has the same two-element form). Conservative —
  what it cannot place is NOT a pool exit — so a caller mapping pool exits onto a retryable
  503 never dresses up a foreign `{:timeout, {GenServer, :call, _}}` as a database outage.
  """
  @spec pool_exit?(term()) :: boolean()
  def pool_exit?({_reason, {module, _fun, _args}}) when module in @pool_modules, do: true
  def pool_exit?(_reason), do: false

  defp closed(tag) when tag in @tags, do: tag

  # Everything else, INCLUDING `ExitTag`'s own catch-all "unknown": both mean "could not
  # classify", and a metric wants ONE label for that, not two spellings that are synonyms.
  defp closed(_tag), do: "other"
end
