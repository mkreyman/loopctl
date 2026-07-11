defmodule Loopctl.ContextRetriever.Scope do
  @moduledoc """
  The explicit Context-Retriever access scope: `(tenant_id, role, actor)`.

  `Loopctl.ContextRetriever.Executor.run/3` takes a `Scope` as its first argument
  (Epic 30, US-30.3). Passing the scope EXPLICITLY — rather than reading it from a
  conn/session — keeps the executor callable in tests without a connection; US-30.4
  builds it from the authenticated API key (`tenant_id` from the key's tenant,
  `role` from the key, `actor_id`/`actor_label` from the key identity).

  ## Security

  `tenant_id` is the isolation boundary. It is the ONLY source of tenant scope the
  executor consults — it is NEVER derived from request params. The executor sets
  the RLS context from `tenant_id` AND adds an explicit `tenant_id` predicate
  (defense-in-depth), and a `tenant_id` appearing in the model-supplied params is
  ignored entirely (never cast, never read).

  A `nil` `tenant_id` denotes a superadmin / no-impersonation context. The
  executor REFUSES it (`{:error, :no_tenant}`) instead of falling back to a
  cross-tenant `AdminRepo` read (AC-30.3.7a) — hence `tenant_id` is NOT an
  `@enforce_keys` field: the struct must be constructible with `tenant_id: nil`
  so that fail-closed edge is reachable and testable.

  ## Fields

  - `tenant_id` — the owning tenant UUID, or `nil` for a superadmin/no-tenant
    context (which the executor refuses).
  - `role` — the caller's role atom (`:agent`, `:orchestrator`, `:user`,
    `:superadmin`). Carried for completeness / future per-role policy; the v1
    executor gates on `tenant_id` presence, not role.
  - `actor_id` — the acting API-key id, recorded on the audit entry (AC-30.3.6).
  - `actor_label` — human-readable actor label, recorded on the audit entry.
  """

  defstruct [:tenant_id, :role, :actor_id, :actor_label]

  @type t :: %__MODULE__{
          tenant_id: String.t() | nil,
          role: atom() | nil,
          actor_id: String.t() | nil,
          actor_label: String.t() | nil
        }
end
