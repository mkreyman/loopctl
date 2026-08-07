defmodule LoopctlWeb.CustodySurface do
  @moduledoc """
  THE list of API operations a custody halt suspends.

  ## Why the halt is scoped rather than total

  A custody halt exists to stop CUSTODY PROGRESS: no story advances, no custody
  authority is minted, and no agent state is written, until a human has cleared
  the halt through the break-glass ceremony. That objective is met by freezing
  the operations that advance the chain.

  It is NOT met by freezing everything the tenant can reach, and freezing
  everything costs real things and buys nothing. A halted tenant that also loses
  its knowledge-base reads, its analytics, its audit history and its change feed
  loses exactly the surfaces an operator needs to INVESTIGATE the halt, and a
  read cannot advance a custody chain in any case. Reads are therefore never
  suspended, on any surface: `custody_operation?/1` returns `false` for every
  GET/HEAD/OPTIONS, unconditionally.

  ## What stays blocked during a halt

    * **Story lifecycle writes** — `POST /stories/:id/{contract,claim,start,
      request-review,report,unclaim,report-done,start-work,review-complete,
      verify,reject,backfill,force-unclaim,recover-cap,artifacts}`. These ARE the
      custody chain.
    * **Bulk story operations** — `POST /stories/bulk/*` and
      `POST /epics/:id/verify-all`. Same transitions, wider blast radius.
    * **Dispatch minting** — `POST /dispatches`. A dispatch mints an ephemeral
      key carrying custody lineage; issuing new custody authority mid-halt would
      let the chain advance around the freeze.
    * **Agent-memory writes** — `POST /memory`, `POST /memory/{promote,graduate}`,
      `DELETE /memory/:id` (AC-28.3.3: a custody-halted key cannot write memory).
      `POST /memory/recall` and `POST /recall` are READS despite their verb, and
      stay open.

  ## What is deliberately NOT blocked

    * **Every read, everywhere** — knowledge base, audit log, change feed,
      story/epic/project reads, analytics, `GET /custody/*`. Investigating a halt
      requires them.
    * **Knowledge-wiki and coordination writes** — curation is not custody, and a
      frozen KB helps nobody diagnose the halt.
    * **Root-of-trust rotation** (`POST /tenants/me/custody-owner-key`,
      `POST /tenants/:id/rotate-audit-key`) — these are REMEDIATION paths. If a
      compromised key is what produced the violations, blocking rotation blocks
      the fix. Both are independently gated by `role: :user` plus a human anchor
      and, for the owner key, proof of possession of the outgoing key.
    * **The superadmin break-glass** (`/api/v1/admin/tenants/:id/clear-halt`) — a
      standalone superadmin key carries no `tenant_id`, so the halt check never
      applies to it. Blocking the exit from a halt would make the halt permanent.

  ## Keeping this list honest

  `custody_controllers/0` names the controllers whose mutating actions MUST be
  covered here.
  `test/loopctl_web/custody_surface_test.exs` walks `LoopctlWeb.Router.__routes__/0`
  and fails if any mutating route on those controllers is not classified as
  custody surface — so adding a new story-lifecycle action cannot silently
  escape the halt. Do not relax that test to make a new route pass; add the
  route's shape here instead.
  """

  @read_methods ~w(GET HEAD OPTIONS)

  # Third path segment under /api/v1/stories/:id/. `bulk` occupies the `:id`
  # position for `POST /stories/bulk/claim`, so the same clause covers both.
  @story_custody_ops ~w(
    contract claim start request-review report unclaim report-done start-work
    review-complete verify reject backfill force-unclaim recover-cap artifacts
    mark-complete
  )

  # Memory actions whose verb is a write but whose SEMANTICS are a read.
  @memory_read_ops ~w(recall)

  @custody_controllers %{
    LoopctlWeb.StoryStatusController => :all_mutating,
    LoopctlWeb.StoryVerificationController => :all_mutating,
    LoopctlWeb.ReviewRecordController => :all_mutating,
    LoopctlWeb.BulkOperationsController => :all_mutating,
    LoopctlWeb.CapRecoveryController => :all_mutating,
    LoopctlWeb.ArtifactReportController => :all_mutating,
    LoopctlWeb.DispatchController => :all_mutating,
    LoopctlWeb.MemoryController => {:all_mutating_except, [:recall, :context]}
  }

  @doc """
  True when this request is a custody operation, i.e. one a custody halt
  suspends.

  Decided from the request METHOD and PATH only — no controller/action is
  available yet, because `Phoenix.Controller.Pipeline` sets
  `conn.private.phoenix_controller` when the controller runs, which is AFTER
  the router pipeline this is consulted from.
  """
  @spec custody_operation?(Plug.Conn.t()) :: boolean()
  def custody_operation?(%Plug.Conn{method: method}) when method in @read_methods, do: false

  def custody_operation?(%Plug.Conn{path_info: ["api", "v1" | rest]}), do: custody_path?(rest)

  def custody_operation?(%Plug.Conn{}), do: false

  @doc """
  Controllers whose MUTATING routes must all be classified as custody surface.

  Consumed by `test/loopctl_web/custody_surface_test.exs`, which binds this
  declaration to the routes the router actually exposes.
  """
  @spec custody_controllers() :: %{module() => :all_mutating | {:all_mutating_except, [atom()]}}
  def custody_controllers, do: @custody_controllers

  # --- Private ---

  # `POST /stories/bulk/claim` matches with `_id = "bulk"`; that is intended.
  defp custody_path?(["stories", _id, op]) when op in @story_custody_ops, do: true
  defp custody_path?(["epics", _id, "verify-all"]), do: true
  defp custody_path?(["dispatches"]), do: true
  defp custody_path?(["memory", op]) when op in @memory_read_ops, do: false
  defp custody_path?(["memory" | _rest]), do: true
  defp custody_path?(_), do: false
end
