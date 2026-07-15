defmodule Loopctl.HeavyRead.OverloadedError do
  @moduledoc """
  Raised when a tenant is over its per-tenant in-flight HeavyRead cap (US-37.5).

  `Loopctl.HeavyRead.all/3` / `one/3` / `all_memory/4` raise this (the default
  over-cap behaviour, `on_overload: :raise`) when
  `Loopctl.HeavyRead.TenantGate.acquire/3` sheds the read, so an API read degrades to
  a clean 429 (with the app error envelope) instead of a pool-exhaustion crash for
  OTHER tenants. The web status mapping lives in
  `LoopctlWeb.Plugs.HeavyReadOverloadHandler` (a `Plug.Exception` impl → 429, the
  same pattern as `LoopctlWeb.Plugs.DBErrorHandler`), and the body is rendered by
  `LoopctlWeb.ErrorJSON` (`"429.json"`).

  Search callers that degrade to keyword fallback instead pass `on_overload: :tag`
  and receive `{:error, :heavy_read_overloaded}` rather than this raise.

  The message and `tenant_id` are safe to log — no query, params, or vector text.
  """
  defexception message: "heavy-read pool over the per-tenant in-flight capacity for this tenant",
               tenant_id: nil
end
