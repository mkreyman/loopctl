defmodule LoopctlWeb.Plugs.RequireUnlineagedCaller do
  @moduledoc """
  The lineage ceiling, MINTING half: a principal that is itself inside a dispatch
  lineage may not obtain a credential outside it.

  `LoopctlWeb.DispatchController` already refuses a caller that tries to start a new
  lineage tree (`root_dispatch_forbidden`) or to parent itself under someone else's
  (`parent_outside_caller_lineage`). That ceiling is only as strong as the set of
  ways to obtain a key: a dispatch-minted `:user`-role key could mint a PLAIN API
  key, and a plain key was minted by no dispatch, so `Dispatches.lineage_for_api_key/2`
  resolves it to `[]` — which is precisely the shape the ceiling admits as "may start a
  root". The principal handed itself, one hop out, the independent root the ceiling
  exists to deny.

  ## Why refuse the mint rather than inherit the lineage

  The alternative was to have the new key inherit the minter's lineage. It cannot be
  made to hold: `lineage_for_api_key/2` reads `dispatches.lineage_path` joined on
  `dispatches.api_key_id`, so a key's lineage IS its dispatch row. Giving an
  `api_keys` row a lineage means either writing a dispatch row for it — at which point
  it is a dispatch, and `POST /api/v1/dispatches` already does that under the ceiling —
  or introducing a SECOND lineage source that every custody gate would have to learn to
  read. A gate reading one source while the ceiling checks another is the failure mode
  this plug exists to close, not a fix for it.

  So the invariant is: **the credentials that carry no lineage may only be minted by a
  principal that has none.** That is the same positive operator test
  `DispatchController.create/2` applies (`caller_lineage == [] and role >= :user`); the
  role half is already enforced by the `RequireRole, role: :user` plug above this one,
  so this plug supplies the lineage half.

  The remedy named in the 403 is one the refused caller can actually perform: mint a
  dispatch beneath its own, which yields an ephemeral key INSIDE its subtree.
  """

  import Plug.Conn

  require Logger

  alias Loopctl.Dispatches

  def init(opts), do: opts

  # `minting_lineage_for_api_key/2`, not `lineage_for_api_key/2`: the latter filters
  # `revoked_at IS NULL` and so reads a revoked-dispatch caller as unlineaged — the
  # ceiling would then rest on cascade revocation staying perfectly coupled to key
  # revocation, a property of a different function's WHERE clause. The question here
  # is whether the principal was EVER inside a lineage, and revocation does not
  # un-ask it.
  def call(%Plug.Conn{assigns: %{current_api_key: %{} = api_key}} = conn, _opts) do
    case Dispatches.minting_lineage_for_api_key(api_key.tenant_id, api_key.id) do
      [] -> conn
      [_ | _] = lineage -> refuse(conn, api_key, lineage)
    end
  end

  # No authenticated key in the assigns. The auth pipeline halts before controller
  # plugs run, so this is unreachable in the router — but a caller we cannot identify
  # is one we cannot show to be unlineaged, and nil is never permissive here.
  def call(conn, _opts), do: refuse(conn, nil, [])

  defp refuse(conn, api_key, lineage) do
    log_refusal(api_key, lineage)

    conn
    |> put_status(:forbidden)
    |> Phoenix.Controller.json(%{
      error: %{
        status: 403,
        code: "api_key_mint_forbidden",
        message:
          "Your key was minted by a dispatch, so it sits inside a lineage. A long-lived " <>
            "API key belongs to no lineage, and minting one would place you outside your " <>
            "own subtree — the separation the custody gates rest on. Mint a dispatch " <>
            "beneath your own instead (POST /api/v1/dispatches with `parent_dispatch_id`); " <>
            "it returns an ephemeral key that stays inside your lineage.",
        remediation: remediation(lineage)
      }
    })
    |> halt()
  end

  defp remediation([]), do: %{learn_more: "https://loopctl.com/wiki/dispatch-lineage"}

  defp remediation(lineage) do
    %{
      your_dispatch_id: List.last(lineage),
      your_lineage_path: lineage,
      learn_more: "https://loopctl.com/wiki/dispatch-lineage"
    }
  end

  # Shares the `lineage_ceiling_refused` log prefix and telemetry event with the two
  # DispatchController refusals: an operator alerting on a principal trying to step
  # outside its lineage wants all three on one counter.
  defp log_refusal(api_key, lineage) do
    Logger.warning(
      "lineage_ceiling_refused: code=api_key_mint_forbidden " <>
        "tenant_id=#{inspect(api_key && api_key.tenant_id)} " <>
        "api_key_id=#{inspect(api_key && api_key.id)} " <>
        "role=#{inspect(api_key && api_key.role)} " <>
        "caller_lineage_root=#{inspect(List.first(lineage))}"
    )

    :telemetry.execute(
      [:loopctl, :custody, :lineage_ceiling_refused],
      %{count: 1},
      %{
        code: "api_key_mint_forbidden",
        tenant_id: api_key && api_key.tenant_id,
        api_key_id: api_key && api_key.id
      }
    )
  end
end
