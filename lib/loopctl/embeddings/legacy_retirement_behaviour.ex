defmodule Loopctl.Embeddings.LegacyRetirementBehaviour do
  @moduledoc """
  DI seam for the US-41.1 legacy-column retirement trigger (GH #551), between
  `Loopctl.Workers.LegacyEmbeddingRetirementWorker` and
  `Loopctl.Embeddings.LegacyRetirement`.

  It exists for ONE branch: the worker's fail-closed handling of a probe that cannot
  read the catalog. That branch is the whole point of the issue — an unreadable probe
  must be loud and retried, never quietly rendered as "already cleaned up" — and it is
  unreachable from a test otherwise, because the test database always answers the
  catalog query successfully. An untested fail-closed path is indistinguishable from
  an absent one.

  Sibling of `Loopctl.Embeddings.ReadPathBehaviour`, and injected the same way:
  `config/test.exs` points `:legacy_retirement` at a Mox mock and
  `Loopctl.DataCase.stub_all_defaults/0` stubs it back to the real module, so every
  test sees production behaviour unless it says otherwise — process-scoped, with
  nothing VM-global written.
  """

  @doc "Read the live legacy-embedding footprint. Whole, or `{:error, _}`."
  @callback probe() :: {:ok, map()} | {:error, term()}

  @doc "Upsert today's observation from a probe reading."
  @callback record(probe :: map(), opts :: keyword()) ::
              {:ok, struct()} | {:error, Ecto.Changeset.t()}

  @doc "Decide whether retirement is owed, given a probe reading and the stored history."
  @callback evaluate(probe :: map(), opts :: keyword()) :: map()
end
