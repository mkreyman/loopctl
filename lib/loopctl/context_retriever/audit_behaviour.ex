defmodule Loopctl.ContextRetriever.AuditBehaviour do
  @moduledoc """
  Behaviour for the Context-Retriever audit writer (Epic 30, US-30.3).

  `Loopctl.ContextRetriever.Executor` writes one `audit_log` entry per executed
  query and — per AC-30.3.6 — treats that write as part of the read's
  correctness (a failed audit insert fails the read closed). This behaviour is
  the config-based DI seam (CLAUDE.md DI convention): production resolves to
  `Loopctl.Audit` (whose `create_log_entry/2` matches the callback), while tests
  map `:context_retriever_audit` to a Mox mock so the fail-closed path can be
  exercised without forcing a real DB insert failure.
  """

  @callback create_log_entry(tenant_id :: Ecto.UUID.t() | nil, attrs :: map()) ::
              {:ok, term()} | {:error, term()}
end
