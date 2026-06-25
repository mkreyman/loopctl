defmodule Loopctl.HeavyReadRepo do
  @moduledoc """
  Dedicated Ecto Repo for heavy, BYPASSRLS analytical/vector reads (US-27.11).

  ## Why a separate repo

  Heavy vector/enumeration reads (semantic search, suggested-links candidates,
  distant-pairs, novelty) previously shared the tiny 3-connection `AdminRepo`
  pool with every other cross-tenant admin op. Three concurrent heavy reads
  could monopolize all admin capacity — this already distorted the #172 fix,
  which had to avoid a per-request transaction precisely to dodge starvation on
  that pool.

  Isolating heavy reads on their own pool (Theme 4):

  - removes that hidden coupling (a slow vector read can't starve light admin
    ops, and vice-versa — they are on physically separate pools), and
  - gives US-27.4 (statement_timeout) and US-27.6b (recall) a clean, pool-level
    lever via `:parameters`, with no per-request transaction.

  ## Pool-level server-side parameters

  This repo's `:parameters` (set in `config/runtime.exs`) carry a server-side
  `statement_timeout` (a CORE GUC, settable via the startup packet — verified).
  So every query on this pool fast-fails at the configured timeout and releases
  the connection, instead of holding it for the full client/pool timeout.

  `hnsw.ef_search` is a pgvector CUSTOM GUC that does not exist until the
  extension loads per-session, so it is NOT settable via `:parameters` on
  managed Postgres (fly mpg/RDS reject it as an unrecognized parameter). If it
  must be raised above the default (40), use
  `ALTER ROLE <heavy_read_role> SET hnsw.ef_search = N` — see
  `docs/runbooks/knowledge-scale.md`. We keep the default for now; recall is
  handled by over-fetch + the US-27.6b under-fill signal.

  ## Tenant isolation

  This repo has BYPASSRLS, so RLS does NOT scope its queries — the `tenant_id`
  predicate is the ONLY isolation. Callers MUST go through `Loopctl.HeavyRead`,
  which structurally requires a `tenant_id` and refuses any query that does not
  filter by it. Never call `Loopctl.HeavyReadRepo.all/one/stream` directly; a
  test guard (`heavy_read_guard_test.exs`) fails the build if any `lib/` module
  other than `Loopctl.HeavyRead` does.

  In dev/test it connects with the same credentials as `Repo`/`AdminRepo`; in
  production it uses the BYPASSRLS role (`ADMIN_DATABASE_URL`).
  """

  use Ecto.Repo,
    otp_app: :loopctl,
    adapter: Ecto.Adapters.Postgres
end
