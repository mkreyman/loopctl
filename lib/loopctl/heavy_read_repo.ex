defmodule Loopctl.HeavyReadRepo do
  @moduledoc """
  Dedicated Ecto Repo for heavy, BYPASSRLS analytical/vector reads (US-27.11).

  ## Why a separate repo

  Heavy vector/enumeration reads (semantic search, suggested-links candidates,
  distant-pairs, novelty) previously shared the tiny 3-connection `AdminRepo`
  pool with every other cross-tenant admin op. Three concurrent heavy reads
  could monopolize all admin capacity.

  Isolating heavy reads on their own pool (Theme 4):

  - removes that hidden coupling (a slow vector read can't starve light admin
    ops, and vice-versa — they are on physically separate pools), and
  - gives US-27.4 (statement_timeout) and US-27.6b (recall) a dedicated, bounded
    pool whose per-read timeout self-drains it under load.

  ## Server-side statement_timeout — per-read `SET LOCAL`, NOT `:parameters` (US-27.13)

  The server-side `statement_timeout` is applied PER-READ via `SET LOCAL` inside the
  `Loopctl.HeavyRead` transaction path (`opts/1` → `all/one` → `transaction/2`), so every
  heavy read fast-fails at the configured timeout and releases the connection.

  It is **deliberately NOT** carried as a connection startup `:parameters` value. Fly MPG
  (and managed Postgres generally) fronts the database with **pgbouncer**, which rejects a
  `statement_timeout` startup parameter with `FATAL 08P01 unsupported startup parameter` —
  this crash-loops the whole pool so it never establishes a connection (the US-27.13
  production outage). `SET LOCAL` inside a transaction is the pgbouncer-safe mechanism and is
  verified to enforce against the live pool. A regression guard
  (`config_pgbouncer_safe_parameters_test.exs`) blocks any repo from re-adding such a
  startup parameter.

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
  production it targets `REPLICA_DATABASE_URL` when an operator sets it (a future gated
  infra op), else falls back to the primary's BYPASSRLS role (`ADMIN_DATABASE_URL`) —
  see `Loopctl.DbCapacity.resolve_replica_url/2`. When `REPLICA_DATABASE_URL` is UNSET the
  resolved DSN is byte-identical to today, so heavy reads still hit the primary. A
  configured replica DSN MUST have the SAME BYPASSRLS read-role capabilities as today's
  admin role (role parity), and MUST only ever back reads through `Loopctl.HeavyRead`
  (never a write). `prepare: :unnamed` below and the per-read `SET LOCAL statement_timeout`
  are pgbouncer-safety and apply to the replica path unchanged. If a configured replica DSN
  is unreachable this pool fails LOUD at boot (it never establishes a connection) rather
  than silently falling back to the primary.
  """

  use Ecto.Repo,
    otp_app: :loopctl,
    adapter: Ecto.Adapters.Postgres,
    prepare: :unnamed
end
