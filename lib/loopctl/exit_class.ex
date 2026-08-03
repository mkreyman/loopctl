defmodule Loopctl.ExitClass do
  @moduledoc """
  The BOUNDED, kind-prefixed metric CLASS for a non-local exit / throw.

  `Loopctl.ExitTag` answers "what was the reason", and its answer is deliberately
  open-ended: ANY exit-reason atom, or ANY exception MODULE name. That is the right
  answer for a log line and the wrong one for a Prometheus LABEL — `error_class` is a
  tag multiplied by `tenant_id` (`Loopctl.ScaleMetrics.degraded_read_tags/1`), so passing
  `ExitTag` through verbatim grows the label's value set with whatever failure modes the
  fleet happens to have, rather than an enumerable set an operator can write an alert
  against.

  So the tag is collapsed onto a CLOSED set: the shapes an operator actually triages —
  an absent pool (`noproc`), a wedged one (`timeout`), one shutting down (`shutdown`) or
  killed (`killed`), plus the two exception MODULES a pooled process actually dies of
  (`Postgrex.Error`, `DBConnection.ConnectionError`) — and `other` for everything else.
  The crash-PROPAGATION shapes are ENUMERATED rather than collapsed because `ExitTag`'s
  clause list exists precisely to stop them degrading to a catch-all: dying of a backend
  error is a different investigation from an unrecognised reason. The kind prefix stays,
  because a dead pool and a throw escaping a guard call for different investigations too.

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

  defp closed(tag) when tag in @tags, do: tag
  defp closed(_tag), do: "other"
end
