defmodule Loopctl.Knowledge.Reranker.Noop do
  @moduledoc """
  The default reranker: returns the fused order unchanged.

  A module rather than a `nil` check so the seam is always present and the feature flag is
  the only thing that decides whether a provider is involved.
  """

  @behaviour Loopctl.Knowledge.Reranker

  @impl true
  def rerank(_scope_or_tenant_id, _query, candidates, _opts),
    do: {:ok, Enum.map(candidates, & &1.id)}
end
