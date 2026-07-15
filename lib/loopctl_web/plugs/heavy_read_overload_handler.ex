defmodule LoopctlWeb.Plugs.HeavyReadOverloadHandler do
  @moduledoc """
  `Plug.Exception` status mapping for a raised `Loopctl.HeavyRead.OverloadedError`
  (US-37.5).

  When a tenant is over its per-tenant in-flight HeavyRead cap and the read is on an
  API path (`Loopctl.HeavyRead`'s default `on_overload: :raise`), the read raises
  `Loopctl.HeavyRead.OverloadedError`. This supplies the HTTP status (429 Too Many
  Requests) for that raised exception when it reaches Phoenix's `render_errors` path;
  `LoopctlWeb.ErrorJSON` renders the safe body (`"429.json"`, with a
  `code: "heavy_read_overloaded"`). Search callers that instead degrade to keyword
  fallback pass `on_overload: :tag` and never raise.

  Mirrors `LoopctlWeb.Plugs.DBErrorHandler`: an auto-compiled `defimpl`, no
  router/endpoint registration needed. `status/1` is pure (no side effects) —
  429 is a normal backpressure response, not a crash, so no structured error log is
  warranted here (contrast the DB-error path's `DBErrorBackstop`).
  """
end

defimpl Plug.Exception, for: Loopctl.HeavyRead.OverloadedError do
  # 429 Too Many Requests: the tenant is over its per-tenant in-flight slice of the
  # heavy-read pool. Backpressure/shed, not a server fault (which would be 5xx).
  def status(_error), do: 429
  def actions(_error), do: []
end
