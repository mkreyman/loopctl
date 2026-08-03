defmodule Loopctl.ApiSpec.Messages do
  @moduledoc """
  Error-message text that BOTH the runtime response and the published OpenAPI spec render.

  One definition, two readers. `LoopctlWeb.FallbackController` builds the body a client
  actually receives; `Loopctl.ApiSpec.Schemas` publishes the `example` and the documented
  response body. When those are two string literals they drift the moment either changes —
  and the drift is invisible, because nothing compares a spec example to a runtime body.

  It happened here (#558): the 429 copy was corrected in the controller to stop asserting a
  backlog that, on the metered fail-open path, was never measured — and the spec kept telling
  clients the opposite. Same technique as `@max_inline_content_bytes`, which CLAUDE.md already
  prescribes for a limit that is both enforced and documented.
  """

  @doc """
  The 429 `ingestion_backlog_exceeded` message.

  Deliberately does NOT claim the backlog is full. The code has TWO causes: the backlog is
  genuinely at/over threshold, OR it could not be MEASURED and the bounded fail-open allowance
  is spent. On the second, nothing was counted and the real backlog may be zero, so the older
  wording ("already has too many … once the backlog drains") stated a fact the server does not
  have and pointed the client at a remedy that may not apply.
  """
  @spec ingestion_backlog_exceeded(pos_integer()) :: String.t()
  def ingestion_backlog_exceeded(retry_after_seconds) do
    "Ingestion is shedding for this tenant: the in-flight backlog is at or over the " <>
      "threshold, or it could not be measured. No items from this batch were " <>
      "enqueued. Retry after #{retry_after_seconds} seconds."
  end
end
