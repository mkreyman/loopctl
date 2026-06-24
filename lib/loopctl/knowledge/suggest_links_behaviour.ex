defmodule Loopctl.Knowledge.SuggestLinksBehaviour do
  @moduledoc """
  DI seam for the suggested-links query executor (US-27.3).

  The `suggested_links` endpoint runs a pgvector similarity scan on `AdminRepo`
  that can raise a `Postgrex.Error` `57014` (statement timeout) at production
  scale. The controller resolves the executor through this behaviour
  (`Application.get_env(:loopctl, :knowledge_suggest_links, Loopctl.Knowledge)`)
  so a test can inject a deterministic DB error via Mox — a real timeout is
  timing-dependent and not reproducible in the test harness (the very reason the
  #170/#172 incident was hard to diagnose).

  `Loopctl.Knowledge` implements this callback directly; production uses it.
  """

  @callback suggest_links(
              tenant_id :: Ecto.UUID.t(),
              article_id :: Ecto.UUID.t(),
              opts :: keyword()
            ) ::
              {:ok, [map()]} | {:error, :not_found} | {:error, :invalid_threshold}
end
