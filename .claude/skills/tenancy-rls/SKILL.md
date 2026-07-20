---
name: tenancy-rls
description: Use when touching data access, tenant scoping, RLS policies, migrations, or the repo topology in loopctl — anything that reads/writes tenant-scoped rows, adds a table, or runs heavy analytical/vector reads. Covers the three Ecto repos (Repo/AdminRepo/HeavyReadRepo), the SET LOCAL RLS mechanism, the transaction-owner invariant, and the pgbouncer statement_timeout gotcha. Triggers on: tenant_id, RLS, row level security, with_tenant, set_rls_context, SET LOCAL, app.current_tenant_id, BYPASSRLS, AdminRepo, HeavyReadRepo, heavy read, statement_timeout, pgbouncer, migration, new table.
---

# Multi-Tenancy & Repo Topology

loopctl isolates every tenant's data with PostgreSQL Row-Level Security. Getting the scoping
mechanics wrong is a **cross-tenant data leak** — the highest-severity bug class in this codebase.
This skill is pointers + invariants, not restated logic; read the cited code before changing it.

## The three repos — pick by intent

| Repo | Role | RLS | Use for |
|------|------|-----|---------|
| `Loopctl.Repo` (`lib/loopctl/repo.ex`) | tenant-scoped app queries | **enforced** (RLS role, no BYPASSRLS) | everything a tenant does |
| `Loopctl.AdminRepo` (`lib/loopctl/admin_repo.ex`) | cross-tenant superadmin ops | BYPASSRLS | superadmin API, custody writes, capability consume |
| `Loopctl.HeavyReadRepo` (`lib/loopctl/heavy_read_repo.ex`) | heavy analytical/vector reads | BYPASSRLS, own pool | semantic search, novelty, suggest-links, distant-pairs |

CLAUDE.md's "Two Repos" line predates `HeavyReadRepo` (US-27.11) — there are **three**. Never route a
heavy vector/enumeration read through `AdminRepo`: that shares a tiny 3-connection pool with every
other admin op and three concurrent heavy reads starve it (`heavy_read_repo.ex:5-17`). Route heavy
reads through `Loopctl.HeavyRead` (`lib/loopctl/heavy_read.ex`), which owns the `HeavyReadRepo` pool.

## Invariants (must hold — cited)

1. **`with_tenant/2` must OWN its transaction** — `repo.ex:95-118`. The RLS context is set with
   `SET LOCAL app.current_tenant_id` / `SET LOCAL ROLE`, which are transaction-scoped. If `with_tenant`
   runs *inside* an existing transaction, its `SET LOCAL` lands in a SAVEPOINT and **persists past the
   savepoint into the outer transaction** — overriding the outer tenant/role for the rest of its life
   (a cross-tenant / role leak). `assert_not_nested!/0` (`repo.ex:110-118`) fails loud to prevent it.
   Inside an enclosing transaction, call `Repo.set_rls_context/1` (`repo.ex:132-142`) directly instead.
2. **RLS context = `set_config('app.current_tenant_id', $1, true)`** — `repo.ex:133-138`. In dev/test the
   connection is a superuser, so `maybe_set_local_role/0` (`repo.ex:152-160`) additionally `SET LOCAL ROLE`
   to a non-superuser (`:rls_role`) so policies actually apply; prod connects as a non-superuser natively.
3. **New tables: `ENABLE ROW LEVEL SECURITY`, never `FORCE`** — the prod role (`schema_admin`) owns the
   tables without BYPASSRLS, so `ENABLE` already applies to it; `FORCE` would also gate the admin paths.
   (CLAUDE.md "Before Changing Any Role Requirement" #4 — NOT "Multi-Tenant Rules" #4, which is the
   `tenant_id`-never-in-`cast` rule cited below.)
4. **`tenant_id` is set programmatically, never in `cast`** — set it on the struct, keep it out of every
   changeset's `cast` allowlist (CLAUDE.md "Multi-Tenant Rules" #4; mirrors the Ecto convention in
   AGENTS.md). A user-supplied `tenant_id` in params must never win.
5. **Every context function takes `tenant_id` as its first argument**, and every tenant-scoped test
   includes a "tenant A cannot see tenant B" isolation case (CLAUDE.md #2/#5).

## The pgbouncer gotcha (US-27.13 — production outage, do not regress)

`HeavyReadRepo` enforces a server-side `statement_timeout` **per-read via `SET LOCAL` inside the
transaction** (`heavy_read.ex:386-415` — `all/3` and `one/3`, both via `with_statement_timeout/4`;
`heavy_read_repo.ex:19-32`) — NOT as a connection startup
`:parameters` value. Fly MPG fronts Postgres with **pgbouncer**, which rejects a `statement_timeout`
startup parameter with `FATAL 08P01 unsupported startup parameter`, crash-looping the whole pool so it
never connects. If you need any per-connection GUC on a pgbouncer-fronted pool, apply it with `SET LOCAL`
inside a transaction, never via `:parameters`.

## Anti-patterns

- Calling `Loopctl.Repo.with_tenant/2` from inside another `Repo.transaction` — raises by design; use
  `set_rls_context/1` in the enclosing transaction.
- Reaching for `AdminRepo` "because RLS is in the way." If a tenant query can't see its own rows, the
  tenant context isn't set — fix the `with_tenant` boundary, don't bypass RLS.
- A heavy vector/semantic/enumeration read on `Repo` or `AdminRepo` instead of `HeavyRead`.
- Adding `statement_timeout` (or any GUC) to a repo's `:parameters` — pgbouncer 08P01.
- A migration that creates a tenant-scoped table without a `tenant_id` column + RLS policy.

## Related

- **`chain-of-custody`** — custody writes/consume run on `AdminRepo`; roles gate who may write.
- **`knowledge-wiki`** — all heavy KB reads route through `HeavyRead`/`HeavyReadRepo`.
- Deep Ecto/OTP mechanics: the global `patterns-ecto` / `patterns-elixir-otp` skills.
