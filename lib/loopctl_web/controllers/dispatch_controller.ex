defmodule LoopctlWeb.DispatchController do
  @moduledoc """
  US-26.2.1 — REST API for dispatch lineage management.
  """

  use LoopctlWeb, :controller

  require Logger

  alias Loopctl.Auth.Role
  alias Loopctl.Dispatches

  action_fallback LoopctlWeb.FallbackController

  # `revoke` sits at the SAME gate as `create`, and deliberately not higher or lower.
  #
  # Not `:user`. CLAUDE.md's rule of thumb puts an operation at `:user` when it IRREVERSIBLY
  # REMOVES DATA or is itself a CUSTODY GATE. Revoking is neither: it sets `revoked_at` on
  # rows that all stay, and it certifies nothing — `get_dispatch/2` reads a revoked row exactly
  # as it reads a live one, so every L4 lineage comparison is untouched by it and a revoke
  # cannot launder custody. It is the DE-escalation of the authority `create` mints, and the
  # delivery loop's orchestrator has to be able to free a stuck credential slot without a human
  # in the loop — the same reason work-breakdown composition is orchestrator-role.
  #
  # Not `:agent` either, and not `exact_role`. Revoking changes the ACTIVE dispatch pool that
  # `Dispatches.select_verifier/3` draws from (`is_nil(revoked_at) and expires_at > now`), and
  # an agent is precisely the principal that must not be able to shape its own verifier pool.
  # `role:` rather than `exact_role:` because the tenant's `:user` operator key must be able to
  # clean up its own tree; nothing here is a separation-of-duties gate, so the hierarchy is not
  # the hole it is on `verify`/`report`.
  #
  # The LINEAGE CEILING is what actually bounds the blast radius, and it is applied in
  # `revoke/2` below — without it any orchestrator dispatch could revoke the tenant's root and
  # take the whole tenant down, or prune the pool until only a verifier it prefers is left.
  plug LoopctlWeb.Plugs.RequireRole, [role: :orchestrator] when action in [:create, :revoke]
  plug LoopctlWeb.Plugs.RequireRole, [role: :agent] when action in [:show, :index, :enrolled_keys]

  # US-26.7.1 — work-breakdown surface requires a human-anchored tenant.
  #
  # `revoke` is anchored with `create` so the whole mutating dispatch surface sits behind one
  # tier gate. It costs an `agent_rooted` tenant nothing: `create` is anchored and so is
  # `Loopctl.Delivery.Placement.place/4`, so such a tenant has no dispatches to revoke.
  plug LoopctlWeb.Plugs.RequireHumanAnchor when action in [:create, :revoke]

  @doc "POST /api/v1/dispatches"
  def create(conn, params) do
    api_key = conn.assigns.current_api_key
    tenant_id = api_key.tenant_id
    parent_id = params["parent_dispatch_id"]

    # The CALLER's own lineage, resolved SERVER-SIDE from the authenticating key —
    # never taken from the request body. See lineage_within_caller?/3.
    caller_lineage = Dispatches.lineage_for_api_key(tenant_id, api_key.id)

    # The operator privilege — starting a NEW tree, and parenting anywhere in the
    # tenant — is decided POSITIVELY, not inferred from an absent lineage.
    # `lineage_for_api_key/2` returns [] for THREE different principals: the tenant's
    # human-anchored operator key, a legacy long-lived env-var key, and a key whose
    # dispatch row no longer resolves. Only the first deserves the privilege, and only
    # it is minted at `role: :user` (Tenants signup ceremony). Treating [] alone as
    # "operator" left every legacy `:orchestrator` key able to hand ITSELF an
    # independently-rooted dispatch for the whole deprecation window — the exact escape
    # the ceiling exists to close.
    operator? = caller_lineage == [] and Role.role_at_least?(api_key.role, :user)

    cond do
      # Role ceiling: a dispatch may not be minted at a HIGHER privilege than the
      # caller's own key. Without this an orchestrator (or any holder of an attestation
      # over an agent key) could mint a `:user`-role dispatch bearing that key, escaping
      # the role hierarchy — the attestation authorizes the KEY, it must not silently
      # elevate the key's PRIVILEGE. A higher requested role is 403'd here.
      role_exceeds_caller?(conn, params["role"]) ->
        reject_role_ceiling(conn, params["role"])

      # G6: Non-root dispatches must provide their parent's dispatch ID. The parent
      # must be active (not revoked, not expired) AND inside the caller's own subtree.
      parent_id ->
        validate_parent_and_create(conn, tenant_id, parent_id, caller_lineage, operator?, params)

      # LINEAGE CEILING (root half). A parentless dispatch starts a NEW, independent
      # lineage tree — one that shares no root with any existing dispatch, and which
      # the L4 separation checks therefore treat as an unrelated principal. A caller
      # that is not the operator must not be able to hand itself one: the structural
      # separation the custody gates rest on is only meaningful if a principal cannot
      # step outside its own tree on demand.
      not operator? ->
        reject_root_mint(conn, api_key, caller_lineage)

      true ->
        do_create_dispatch(conn, tenant_id, params)
    end
  end

  # True only when the requested role parses to a KNOWN role strictly above the
  # caller's. An unparseable/absent role is left to `create_dispatch` to reject with
  # its own `:invalid_role` error (this guard is a ceiling, not a validator).
  defp role_exceeds_caller?(conn, requested) do
    caller_role = conn.assigns.current_api_key.role

    case parse_requested_role(requested) do
      {:ok, role} -> not Role.role_at_least?(caller_role, role)
      :error -> false
    end
  end

  defp parse_requested_role(role) when role in ["agent", "orchestrator", "user", "superadmin"],
    do: {:ok, String.to_existing_atom(role)}

  defp parse_requested_role(role) when role in [:agent, :orchestrator, :user, :superadmin],
    do: {:ok, role}

  defp parse_requested_role(_), do: :error

  defp reject_role_ceiling(conn, requested) do
    conn
    |> put_status(:forbidden)
    |> json(%{
      error: %{
        status: 403,
        code: "dispatch_role_exceeds_caller",
        message:
          "A dispatch cannot be minted at a higher role (#{inspect(requested)}) than the " <>
            "caller's own key (#{conn.assigns.current_api_key.role}). Mint the dispatch at " <>
            "the caller's role or lower.",
        remediation: %{learn_more: "https://loopctl.com/wiki/dispatch-lineage"}
      }
    })
  end

  defp validate_parent_and_create(conn, tenant_id, parent_id, caller_lineage, operator?, params) do
    case Dispatches.get_dispatch(tenant_id, parent_id) do
      {:ok, parent} ->
        now = DateTime.utc_now()

        cond do
          parent.revoked_at || DateTime.compare(parent.expires_at, now) != :gt ->
            conn
            |> put_status(:forbidden)
            |> json(%{
              error: %{
                code: "parent_dispatch_expired",
                status: 403,
                message: "Parent dispatch is expired or revoked"
              }
            })

          not lineage_within_caller?(parent.lineage_path, caller_lineage, operator?) ->
            reject_lineage_escape(conn, conn.assigns.current_api_key, caller_lineage, parent_id)

          true ->
            do_create_dispatch(conn, tenant_id, params)
        end

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{message: "Parent dispatch not found", status: 404}})
    end
  end

  # LINEAGE CEILING (parent half). Rejecting only the parentless case would leave the
  # same escape open one step further out: any dispatch in the tenant is enumerable
  # via GET /api/v1/dispatches, so a caller could name a parent under a DIFFERENT root
  # and mint itself into that unrelated tree. A minted dispatch must therefore descend
  # from the caller's own dispatch — `parent.lineage_path` must have the caller's
  # lineage as a prefix.
  #
  # The OPERATOR key may parent anywhere in its tenant: it is not inside any tree, so
  # it cannot escape one. The same reasoning covers a []-lineage NON-operator (a legacy
  # env-var key): it has no subtree to step outside of, and the ceiling exists to stop a
  # principal escaping ITS OWN tree. Refusing it here closed the only remaining mint it
  # had — root minting is already operator-only — leaving a legacy `:orchestrator` key
  # unable to obtain a lineage by any request at all, against the documented deprecation
  # window. Naming a parent gives it a lineage, which SUBJECTS it to the custody gates.
  # A caller that IS inside a tree must stay inside it.
  defp lineage_within_caller?(_parent_lineage, _caller_lineage, true), do: true
  defp lineage_within_caller?(_parent_lineage, [], false), do: true

  defp lineage_within_caller?(parent_lineage, [_ | _] = caller_lineage, false)
       when is_list(parent_lineage),
       do: List.starts_with?(parent_lineage, caller_lineage)

  defp lineage_within_caller?(_parent_lineage, _caller_lineage, false), do: false

  defp reject_root_mint(conn, api_key, caller_lineage) do
    log_ceiling_refusal("root_dispatch_forbidden", api_key, caller_lineage, nil)

    conn
    |> put_status(:forbidden)
    |> json(%{
      error: %{
        status: 403,
        code: "root_dispatch_forbidden",
        message:
          "A parentless dispatch starts a NEW independent lineage tree, which only the " <>
            "tenant's own operator key (a `user`-role key that no dispatch minted) may do. " <>
            root_mint_remedy(caller_lineage),
        remediation: root_mint_remediation(caller_lineage)
      }
    })
  end

  # The remedy must be one the REFUSED caller can actually perform. "Mint inside your
  # own lineage" is meaningless to a caller that has none — and `your_dispatch_id`
  # would be a bare null there, which is how the previous wording read to every legacy
  # key. Name a parent it can obtain instead.
  defp root_mint_remedy([]),
    do:
      "Your key was not minted by a dispatch, so you have no lineage of your own: pass " <>
        "`parent_dispatch_id` naming any active dispatch in your tenant (GET " <>
        "/api/v1/dispatches), or have the tenant's `user`-role operator key mint the root."

  defp root_mint_remedy(_caller_lineage),
    do: "Pass `parent_dispatch_id` and mint this dispatch inside your own lineage."

  # The remediation is only actionable if the caller can NAME its own dispatch, and
  # nothing else on this API tells it which row is its own. It is already resolved
  # server-side as the last element of the caller's lineage, so hand it back — and OMIT
  # the key entirely when there is no such row, rather than emitting null.
  defp root_mint_remediation([]), do: %{learn_more: "https://loopctl.com/wiki/dispatch-lineage"}

  defp root_mint_remediation(caller_lineage) do
    %{
      your_dispatch_id: List.last(caller_lineage),
      your_lineage_path: caller_lineage,
      learn_more: "https://loopctl.com/wiki/dispatch-lineage"
    }
  end

  defp reject_lineage_escape(conn, api_key, caller_lineage, parent_id) do
    log_ceiling_refusal("parent_outside_caller_lineage", api_key, caller_lineage, parent_id)

    conn
    |> put_status(:forbidden)
    |> json(%{
      error: %{
        status: 403,
        code: "parent_outside_caller_lineage",
        message:
          "The requested parent dispatch is not in your lineage. A dispatch may only be " <>
            "minted beneath the caller's own dispatch, so that the lineage separation the " <>
            "custody gates rest on cannot be sidestepped. Use your own dispatch id (or one " <>
            "of its descendants) as `parent_dispatch_id`.",
        remediation: %{
          your_dispatch_id: List.last(caller_lineage),
          your_lineage_path: caller_lineage,
          learn_more: "https://loopctl.com/wiki/dispatch-lineage"
        }
      }
    })
  end

  # A principal trying to place itself in a lineage it does not belong to is the
  # highest-signal event on this endpoint. Without this the refusals were invisible:
  # a 403 body to the attacker and nothing at all to the operator.
  defp log_ceiling_refusal(code, api_key, caller_lineage, parent_id) do
    Logger.warning(
      "lineage_ceiling_refused: code=#{code} tenant_id=#{api_key.tenant_id} " <>
        "api_key_id=#{api_key.id} role=#{api_key.role} " <>
        "caller_lineage_root=#{inspect(List.first(caller_lineage))} " <>
        "requested_parent_dispatch_id=#{inspect(parent_id)}"
    )

    :telemetry.execute(
      [:loopctl, :custody, :lineage_ceiling_refused],
      %{count: 1},
      %{code: code, tenant_id: api_key.tenant_id, api_key_id: api_key.id}
    )
  end

  defp do_create_dispatch(conn, tenant_id, params) do
    case Dispatches.create_dispatch(tenant_id, params) do
      {:ok, %{dispatch: dispatch, raw_key: raw_key}} ->
        conn
        |> put_status(:created)
        |> json(%{
          data: %{
            dispatch: serialize(dispatch),
            api_key: %{
              raw_key: raw_key,
              role: dispatch.role,
              agent_id: dispatch.agent_id,
              expires_at: dispatch.expires_at
            },
            next_action: %{
              description:
                "Pass the raw_key to the sub-agent via launch arguments. Never store it.",
              learn_more: "https://loopctl.com/wiki/dispatch-lineage"
            }
          }
        })

      {:error, :parent_not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{message: "Parent dispatch not found", status: 404}})

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, changeset}

      # LCP-1 §9.2 enrollment-attestation failures — each is a DISTINCT condition
      # whose client recovery differs, so map them to descriptive bodies with stable
      # codes rather than collapsing to one opaque 422 (mirrors RequireSignedClaim).
      {:error, reason}
      when reason in [
             :attestation_required,
             :owner_key_not_registered,
             :attestation_alg_mismatch,
             :malformed_attestation_encoding
           ] ->
        render_attestation_error(conn, reason)

      {:error, {:attestation_invalid, _detail}} ->
        render_attestation_error(conn, :attestation_invalid)

      {:error, _reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{message: "Dispatch creation failed", status: 422}})
    end
  end

  # 409 when the tenant must FIRST register an owner key (a precondition the caller
  # can fix without touching this request); 422 for the malformed/invalid/missing
  # attestation shapes (the caller must fix the attestation it supplied).
  defp render_attestation_error(conn, :owner_key_not_registered) do
    conn
    |> put_status(:conflict)
    |> json(%{
      error: %{
        status: 409,
        code: "owner_key_not_registered",
        message:
          "Enrolling an agent key requires a §9.2 authorizer. This tenant has no owner " <>
            "key registered and this dispatch has no active enrolled parent to delegate " <>
            "from. Register an owner key (POST /api/v1/tenants/me/custody-owner-key) first.",
        remediation: %{learn_more: "https://loopctl.com/wiki/chain-of-custody"}
      }
    })
  end

  defp render_attestation_error(conn, reason) do
    {code, message} = attestation_error_detail(reason)

    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: %{
        status: 422,
        code: Atom.to_string(code),
        message: message,
        remediation: %{learn_more: "https://loopctl.com/wiki/chain-of-custody"}
      }
    })
  end

  defp attestation_error_detail(:attestation_required),
    do:
      {:attestation_required,
       "Enrolling an agent key requires a §9.2 owner/parent attestation over that key. " <>
         "Include the `attestation` (owner/parent signature) in the request."}

  defp attestation_error_detail(:attestation_alg_mismatch),
    do:
      {:attestation_alg_mismatch,
       "The dispatch `alg` does not match the authorizing key's algorithm (LCP-1 §6.1). " <>
         "Sign the attestation with, and declare, the authorizer's algorithm."}

  defp attestation_error_detail(:malformed_attestation_encoding),
    do:
      {:malformed_attestation_encoding,
       "The `attestation` could not be decoded: send it as raw 64-byte signature " <>
         "bytes or a 128-character hex string."}

  defp attestation_error_detail(:attestation_invalid),
    do:
      {:attestation_invalid,
       "The owner/parent attestation did not verify against the authorizing key " <>
         "(LCP-1 §9.2). Re-sign the exact tenant/agent-pubkey/lineage/conditions preimage."}

  @doc "GET /api/v1/dispatches/:id"
  def show(conn, %{"id" => id}) do
    tenant_id = conn.assigns.current_api_key.tenant_id

    case Dispatches.get_dispatch(tenant_id, id) do
      {:ok, dispatch} ->
        json(conn, %{data: serialize(dispatch)})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{message: "Not found", status: 404}})
    end
  end

  @doc """
  POST /api/v1/dispatches/:id/revoke

  Revokes a dispatch AND EVERY DESCENDANT, and the ephemeral api_key each one
  minted (`Dispatches.revoke/3`). The reachable half of a remediation that until
  now only existed as a context function: nothing outside the app could call it,
  so a leaked or stranded ephemeral key could only be waited out.

  What it is usually for: a session dispatch whose session is gone. Its key is
  still `revoked_at IS NULL`, so it OCCUPIES its agent's slot in
  `api_keys_one_role_per_agent_idx` and every later mint for that agent at that
  role is refused 422 `agent already has an active key with this role` — the
  index tests `revoked_at IS NULL` and CANNOT test `expires_at` (a partial-index
  predicate must be IMMUTABLE and `now()` is STABLE), so only a revoke frees it
  before the TTL.

  Idempotent: an already-revoked dispatch answers 200 with `revoked_count: 0` and
  its original `revoked_at`. That holds for a CONCURRENT retry too, not only a
  sequential one: the candidate read runs outside the transaction and is advisory,
  so the UPDATE re-asserts `revoked_at IS NULL` itself
  (`Dispatches.revoke_dispatch_rows/3`) and `revoked_count` is what that statement
  changed. So a retry never rewrites a revocation timestamp an audit reader may be
  relying on, and never appends a second `dispatch_revoked` entry to the chain.

  It does NOT clear `stories.implementer_dispatch_id`. That is custody
  provenance, and `Progress`'s lineage lookups resolve a revoked dispatch row
  exactly as they resolve a live one, so no L4 comparison changes.

  WHO MAY CALL IT, beyond the `role: :orchestrator` plug: a dispatch-minted
  caller, for a dispatch inside its own subtree (`403
  dispatch_outside_caller_lineage` otherwise), and the tenant's operator key —
  a `user`-role key that no dispatch minted — anywhere in its tenant. Any OTHER
  unlineaged caller, which is what a legacy `LOOPCTL_ORCH_KEY` is, is `403
  unlineaged_revoke_forbidden`. See `revoke_ceiling/3`.
  """
  def revoke(conn, %{"id" => id}) do
    api_key = conn.assigns.current_api_key
    tenant_id = api_key.tenant_id
    caller_lineage = Dispatches.lineage_for_api_key(tenant_id, api_key.id)
    operator? = caller_lineage == [] and Role.role_at_least?(api_key.role, :user)

    case Dispatches.get_dispatch(tenant_id, id) do
      {:ok, dispatch} ->
        case revoke_ceiling(dispatch.lineage_path, caller_lineage, operator?) do
          :ok ->
            do_revoke_dispatch(conn, tenant_id, dispatch, caller_lineage)

          {:error, :unlineaged_caller} ->
            reject_unlineaged_revoke(conn, api_key, dispatch.id)

          {:error, :outside_lineage} ->
            reject_revoke_escape(conn, api_key, caller_lineage, dispatch.id)
        end

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{message: "Not found", status: 404}})
    end
  end

  # THE CEILING `create` APPLIES, MINUS THE ONE CLAUSE THAT MUST NOT BE INHERITED —
  # `lineage_within_caller?(_, [], false)`, which admits an unlineaged NON-operator.
  #
  # On `create` that clause is paid for: naming a parent GIVES the caller a lineage and
  # therefore SUBJECTS it to every custody gate, and refusing it closed the only mint a legacy
  # env-var key had left (root minting is already operator-only), against the documented
  # deprecation window. NOTHING COMPENSATES HERE. Revoke takes no parent, hands back no
  # lineage, and destroys rather than creates, so the same clause reads: any `:orchestrator`
  # key that no dispatch minted may revoke ANY dispatch in the tenant — including the
  # operator's root, cascading to every descendant, which is precisely the blast radius the
  # 403 below claims to prevent. "A legacy key has no subtree to step outside of" is true and
  # is the problem restated: it has no subtree to be BOUNDED BY.
  #
  # So an unlineaged caller passes only the POSITIVE operator test (`[]` AND `role >= :user`)
  # the mint half already computes — the same shape
  # `Loopctl.Delivery.Placement.may_mint_session_dispatch/2` applies to an unlineaged caller,
  # and the reason `operator?` is computed on this action at all (it was inert until now,
  # because the `[]` clause returned true for everyone).
  #
  # Nothing legitimate is stranded by the refusal. The tenant's `user`-role operator key
  # revokes anywhere in its tenant; a dispatch-minted caller revokes inside its own subtree;
  # `POST /api/v1/stories/:id/force-unclaim` revokes a parked story's session dispatch through
  # the context, which this ceiling does not sit on; and both TTL sweeps
  # (`RevokeExpiredDispatchesWorker`, `RevokeExpiredApiKeysWorker`) still run.
  #
  # Total over what reaches it: `caller_lineage` is `lineage_for_api_key/2`'s return, always a
  # list. No catch-all for a nil `lineage_path` — the column is NOT NULL with a `[]` default,
  # so a nil there is a broken invariant, and `List.starts_with?/2` raising (nothing revoked)
  # is the right answer rather than an unreachable clause that reads as a guard. Placement
  # removed exactly such a clause after `bin/mutate.sh` proved nothing could reach it.
  defp revoke_ceiling(_lineage_path, _caller_lineage, true), do: :ok
  defp revoke_ceiling(_lineage_path, [], false), do: {:error, :unlineaged_caller}

  defp revoke_ceiling(lineage_path, [_ | _] = caller_lineage, false) do
    if List.starts_with?(lineage_path, caller_lineage),
      do: :ok,
      else: {:error, :outside_lineage}
  end

  # An unlineaged caller below `:user`. Its own code, not `dispatch_outside_caller_lineage`:
  # that message tells the caller to revoke one of its own dispatches instead, and this caller
  # has none — "a refusal that names an action the refused caller cannot take is a dead end,
  # not a remediation" (the chain-of-custody skill's recurring defect on this surface). It is
  # also the code an operator wants to see separately in the `lineage_ceiling_refused` log: a
  # legacy env-var key is a CONFIGURATION state inside the deprecation window, not a principal
  # reaching into another's tree.
  defp reject_unlineaged_revoke(conn, api_key, dispatch_id) do
    log_ceiling_refusal("unlineaged_revoke_forbidden", api_key, [], dispatch_id)

    conn
    |> put_status(:forbidden)
    |> json(%{
      error: %{
        status: 403,
        code: "unlineaged_revoke_forbidden",
        message:
          "Your key was minted by no dispatch, so it carries no lineage — and a revoke " <>
            "CASCADES to every descendant, so there is no subtree that would bound it. Only " <>
            "the tenant's operator key (a `user`-role key that no dispatch minted) may revoke " <>
            "anywhere in its tenant. Use that key; or, to park a story, POST " <>
            "/api/v1/stories/:id/force-unclaim, which revokes that story's own session " <>
            "dispatch; or mint a dispatch under an active parent (POST /api/v1/dispatches " <>
            "with `parent_dispatch_id`) and revoke from inside that lineage. An expired " <>
            "dispatch is swept at its TTL either way.",
        remediation: %{learn_more: "https://loopctl.com/wiki/dispatch-lineage"}
      }
    })
  end

  defp do_revoke_dispatch(conn, tenant_id, dispatch, caller_lineage) do
    case Dispatches.revoke(tenant_id, dispatch.id, actor_lineage: caller_lineage) do
      {:ok, count} ->
        json(conn, %{
          data: %{
            dispatch: revoked_view(tenant_id, dispatch),
            revoked_count: count,
            note:
              "Revokes this dispatch AND its descendants, plus the ephemeral api_key each " <>
                "minted. `implementer_dispatch_id` on any story is deliberately left as it " <>
                "is: it is custody provenance, and the lineage it names still resolves."
          }
        })

      {:error, _reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{
          error: %{
            status: 422,
            code: "dispatch_revoke_failed",
            message: "Dispatch revocation failed. Nothing was revoked; retry is safe."
          }
        })
    end
  end

  # Re-read so `revoked_at` is the COMMITTED value rather than the pre-revoke `nil`. An
  # already-revoked dispatch re-reads to its ORIGINAL timestamp, which is what makes the
  # idempotent answer honest rather than merely quiet.
  #
  # NOT a hard match. This read happens AFTER the revoke committed, so a miss is not a failed
  # revocation, and a `MatchError` would answer 500 — telling the caller the revoke failed and
  # making "Nothing was revoked; retry is safe" the wrong reading of a revoke that happened.
  # The `rescue` is the same call: `get_dispatch/2` is an ordinary AdminRepo read on the
  # 3-connection pool, so a checkout timeout is a RAISE and not an `{:error, _}`, exactly as
  # `Progress.revoke_released_session_credential/3` rescues its own post-commit cleanup.
  #
  # `nil` rather than the struct in hand: serializing the PRE-revoke row would answer
  # `revoked_at: null` inside a 200 that just revoked, which is the same false "nothing
  # happened" reading moved one field over. An explicit null plus `revoked_count` says what is
  # known and claims nothing that is not.
  defp revoked_view(tenant_id, dispatch) do
    case Dispatches.get_dispatch(tenant_id, dispatch.id) do
      {:ok, revoked} ->
        serialize(revoked)

      {:error, :not_found} ->
        Logger.warning(
          "dispatch revoke committed but the row could not be re-read: " <>
            "tenant_id=#{tenant_id} dispatch_id=#{dispatch.id}"
        )

        nil
    end
  rescue
    error ->
      Logger.warning(
        "dispatch revoke committed but the re-read RAISED: tenant_id=#{tenant_id} " <>
          "dispatch_id=#{dispatch.id} error=#{inspect(error)}"
      )

      nil
  end

  defp reject_revoke_escape(conn, api_key, caller_lineage, dispatch_id) do
    log_ceiling_refusal("dispatch_outside_caller_lineage", api_key, caller_lineage, dispatch_id)

    conn
    |> put_status(:forbidden)
    |> json(%{
      error: %{
        status: 403,
        code: "dispatch_outside_caller_lineage",
        message:
          "That dispatch is not in your lineage. A dispatch may only be revoked by a caller " <>
            "it descends from, because revocation cascades to every descendant — an " <>
            "unrestricted revoke would let one principal take down another's whole tree, and " <>
            "let an implementer narrow the pool its own verifier is chosen from. Revoke one " <>
            "of your own dispatches (or a descendant of one), or ask the tenant's `user`-role " <>
            "operator key, which may revoke anywhere in its tenant.",
        remediation: revoke_escape_remediation(caller_lineage)
      }
    })
  end

  # Same discipline as the mint refusals: OMIT `your_dispatch_id` rather than emit a bare null
  # when the caller has no dispatch of its own, and never name a remedy it cannot perform.
  defp revoke_escape_remediation([]),
    do: %{learn_more: "https://loopctl.com/wiki/dispatch-lineage"}

  defp revoke_escape_remediation(caller_lineage) do
    %{
      your_dispatch_id: List.last(caller_lineage),
      your_lineage_path: caller_lineage,
      learn_more: "https://loopctl.com/wiki/dispatch-lineage"
    }
  end

  @doc "GET /api/v1/dispatches"
  def index(conn, params) do
    tenant_id = conn.assigns.current_api_key.tenant_id

    opts =
      []
      |> maybe_add(:role, params["role"])
      |> maybe_add(:active_only, params["active_only"] == "true")
      |> maybe_add(:limit, parse_int(params["limit"]))
      |> maybe_add(:offset, parse_int(params["offset"]))

    result = Dispatches.list_dispatches(tenant_id, opts)

    json(conn, %{
      data: Enum.map(result.data, &serialize/1),
      meta: result.meta
    })
  end

  @doc """
  GET /api/v1/dispatches/enrolled-keys

  LCP-1 §9.1.1 transparency: the enrolled agent-key set reconstructed from the
  hash-chained audit log (not the dispatches table). Keyset-paged via `cursor`.
  Read-only; a tenant compares this against the keys it generated to detect any
  operator-minted key.
  """
  def enrolled_keys(conn, params) do
    tenant_id = conn.assigns.current_api_key.tenant_id

    opts =
      []
      |> maybe_add(:limit, parse_int(params["limit"]))
      |> maybe_add(:cursor, parse_int(params["cursor"]))

    result = Dispatches.enrolled_agent_keys(tenant_id, opts)
    json(conn, result)
  end

  defp serialize(d) do
    %{
      id: d.id,
      tenant_id: d.tenant_id,
      parent_dispatch_id: d.parent_dispatch_id,
      agent_id: d.agent_id,
      story_id: d.story_id,
      role: d.role,
      lineage_path: d.lineage_path,
      expires_at: d.expires_at,
      revoked_at: d.revoked_at,
      created_at: d.created_at
    }
  end

  defp maybe_add(opts, _key, nil), do: opts
  defp maybe_add(opts, _key, false), do: opts
  defp maybe_add(opts, key, value), do: Keyword.put(opts, key, value)

  defp parse_int(nil), do: nil

  defp parse_int(str) when is_binary(str) do
    case Integer.parse(str) do
      {n, ""} -> n
      _ -> nil
    end
  end
end
