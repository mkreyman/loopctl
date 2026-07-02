defmodule Loopctl.Knowledge.SimilaritySearch.Behaviour do
  @moduledoc """
  Injectable contract for the nearest-neighbour similarity lookup that
  `Loopctl.Workers.ArticleLinkingWorker` depends on.

  ## Why this behaviour exists

  The auto-link worker's LINKING logic (the `relates_to` / `potential_conflict`
  threshold split, dedup against existing links in both directions, the audit
  event, idempotency) is entirely deterministic — but it was reachable in tests
  ONLY through the concrete `Loopctl.Knowledge.VectorSearch.nearest/4`, which runs
  the pgvector kNN through `Loopctl.HeavyRead` under a short
  `SET LOCAL statement_timeout` transaction (250 ms in the test env). On a loaded
  local DB that timed heavy read (and, via the documented Sandbox `SET LOCAL`
  persistence, the audit `INSERT` that follows it in the same test transaction)
  could be cancelled by Postgres (`57014 query_canceled`), making the worker's
  UNIT tests intermittently fail.

  Injecting the similarity lookup behind this behaviour lets those unit tests feed
  the worker deterministic candidate lists — asserting the linking logic without
  ever entering the timed heavy-read path. The real `VectorSearch.nearest/4` path
  keeps its own dedicated coverage.

  ## Implementations

    * Production/dev — `Loopctl.Knowledge.VectorSearch` (its `nearest/4` matches
      this callback exactly; wired via `config/config.exs`).
    * Test — `Loopctl.MockArticleSimilaritySearch` (a Mox mock; wired via
      `config/test.exs`).

  Resolved by the worker with config-based DI:
  `Application.get_env(:loopctl, :article_similarity_search, Loopctl.Knowledge.VectorSearch)`.
  """

  @typedoc """
  A nearest-neighbour candidate row — the exact shape
  `Loopctl.Knowledge.VectorSearch.nearest/4` returns (`VectorSearch.candidate/0`).
  The worker keys on `:id` and `:similarity_score`.
  """
  @type candidate :: %{
          id: Ecto.UUID.t(),
          title: String.t(),
          category: atom() | nil,
          similarity_score: float()
        }

  @doc """
  Returns up to `k` nearest-neighbour candidate maps for `target_embedding`,
  highest similarity first, scoped to `tenant_id`.

  Mirrors `Loopctl.Knowledge.VectorSearch.nearest/4`: `opts` may carry
  `:exclude_id`, `:project_or_global`, `:threshold`, `:pool`, etc.
  """
  @callback nearest(
              tenant_id :: binary(),
              target_embedding :: term(),
              k :: pos_integer(),
              opts :: keyword()
            ) :: [candidate()]
end
