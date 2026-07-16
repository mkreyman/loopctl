defmodule Loopctl.Memory.Scope do
  @moduledoc """
  The explicit memory-access scope: `(tenant_id, subject_id, project_id)`.

  Every `Loopctl.Memory` public function takes a `Scope` as its first argument.
  Passing the scope EXPLICITLY (rather than reading it from a conn/session) keeps
  the context callable in tests without a connection; US-28.3 builds the scope
  from the authenticated API key (`tenant_id` from the key's tenant, `subject_id`
  via `Loopctl.Memory.subject_id_for/1`, `project_id` from the authorized
  request context).

  ## Security

  `tenant_id` and `subject_id` are the isolation boundary. They are NEVER derived
  from request params — the write path sets them programmatically on the struct,
  and the recall path (on the BYPASSRLS heavy-read pool) enforces them as an
  explicit `(tenant_id, subject_id)` predicate backed by a structural guard
  (`Loopctl.HeavyRead.all_memory/4`).

  ## Fields

  - `tenant_id` — the owning tenant UUID (required)
  - `subject_id` — the memory scope owner = the API-key identity (required)
  - `project_id` — optional project UUID. It is a PARTITION key, NOT an isolation
    boundary (`tenant_id`/`subject_id` are). `nil` means GLOBAL — the rows whose
    `project_id` column is NULL — NOT "every project in the tenant". On `recall/2`
    a `nil` scope is therefore GLOBAL-ONLY (it does not union across projects), and
    a present `project_id` recalls `global ∪ that project`. (#411 Gap 2 — see
    `Loopctl.Memory.recall/2`.)
  - `session_id` — optional session identifier. Not an isolation key; carried on the
    scope only so the explicit promotion trigger `Loopctl.Memory.promote_session/1`
    (US-29.2) can accept a `%{scope | session_id: ...}` struct without a second
    positional argument. `nil` for every non-promotion path.
  """

  @enforce_keys [:tenant_id, :subject_id]
  defstruct [:tenant_id, :subject_id, :project_id, :session_id]

  @type t :: %__MODULE__{
          tenant_id: String.t(),
          subject_id: String.t(),
          project_id: String.t() | nil,
          session_id: String.t() | nil
        }
end
