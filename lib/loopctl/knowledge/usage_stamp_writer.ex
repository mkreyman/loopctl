defmodule Loopctl.Knowledge.UsageStampWriter do
  @moduledoc """
  The production `Loopctl.Knowledge.UsageStampWriterBehaviour` — the importance stamp's two
  `update_all` statements, delegated verbatim to `Loopctl.AdminRepo`.

  `AdminRepo` and not `Repo`: the stamp reconciles the whole of one tenant's corpus from a
  nightly worker that holds no request scope, and the writes carry their own
  `tenant_id` predicate rather than relying on RLS. Nothing here may grow logic — see
  `Loopctl.Knowledge.UsageScan` for why the adapter is thin.
  """

  @behaviour Loopctl.Knowledge.UsageStampWriterBehaviour

  @impl true
  defdelegate update_all(queryable, updates), to: Loopctl.AdminRepo
end
