defmodule Loopctl.Knowledge.UsageScan do
  @moduledoc """
  The production `Loopctl.Knowledge.UsageScanBehaviour` — the nightly importance
  aggregate's heavy read, delegated verbatim to `Loopctl.HeavyRead`.

  A thin adapter rather than `@behaviour` on the facade itself: `Loopctl.HeavyRead` is the
  ONE sanctioned entry point to the heavy-read pool for the whole application, and tying it
  to a callback shaped for a single caller would invite the next caller to widen the
  behaviour instead of adding its own. Nothing here may grow logic — the whole point is that
  the real path and the injected path differ by nothing but the module name.
  """

  @behaviour Loopctl.Knowledge.UsageScanBehaviour

  @impl true
  defdelegate all(tenant_id, queryable, opts), to: Loopctl.HeavyRead
end
