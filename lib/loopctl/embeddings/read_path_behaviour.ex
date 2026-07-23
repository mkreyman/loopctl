defmodule Loopctl.Embeddings.ReadPathBehaviour do
  @moduledoc """
  DI seam for the US-41.1 embedding read-path cutover decision.

  `Loopctl.Embeddings.side_table_reads_enabled?/0` used to read the
  `SystemConfig` flag directly. That flag is cached in `:persistent_term`, which
  is **VM-global**: a test could only exercise the side-table path by MUTATING
  global state for the whole node, then putting it back in `on_exit`. Two test
  modules did exactly that, and the mutation intermittently leaked across the
  boundary — a test that had just asserted the flag was on would run its query
  after the value had been reset, silently take the LEGACY path, find no legacy
  embedding, and fail with an empty result set. The failures looked like a
  vector-recall bug (`left: []`) and moved around between modules and runs,
  which is what made them read as an ANN flake.

  Behind this behaviour the decision is an injected collaborator: production
  resolves to `Loopctl.Embeddings.SystemConfigReadPath` (unchanged semantics —
  the operator still flips one `SystemConfig` row with no redeploy), and tests
  resolve to a Mox mock whose stub is scoped to the calling PROCESS. Nothing
  global is written, so the read path a test selects cannot be observed by any
  other test.
  """

  @doc """
  Whether recall should read the dimension-tagged SIDE TABLE (`true`) or the
  legacy `articles.embedding` / `memories.embedding` column (`false`).
  """
  @callback side_table_reads_enabled?() :: boolean()
end
