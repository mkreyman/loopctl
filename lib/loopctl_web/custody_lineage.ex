defmodule LoopctlWeb.CustodyLineage do
  @moduledoc """
  The custody-call options a controller resolves from the AUTHENTICATING key, in one place so
  every route hands the context the same principal.

  `chg_root_opts/1` (US-47.5) is the lineage `Loopctl.Changes.ReviewCustody` judges the
  chg-root refusal on — `chg_root_cannot_verify` on verify, reject, verify-all, backfill and
  the bulk paths; `chg_root_review_only` on claim, bulk claim and report. It is the caller's
  MINTING lineage (`Loopctl.Dispatches.minting_lineage_for_api_key/2`), revoked or not, so a
  chg key whose dispatch has expired — live lineage `[]`, which reject admits — is still
  chg's. Never read from the request.
  """

  alias Loopctl.Dispatches

  @doc "`[caller_minting_lineage: lineage]` for `api_key`, resolved server-side."
  @spec chg_root_opts(%{tenant_id: Ecto.UUID.t(), id: Ecto.UUID.t()}) :: keyword()
  def chg_root_opts(%{tenant_id: tenant_id, id: api_key_id}),
    do: [caller_minting_lineage: Dispatches.minting_lineage_for_api_key(tenant_id, api_key_id)]
end
