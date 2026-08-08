defmodule Loopctl.Dispatches do
  @moduledoc """
  US-26.2.1 — Context module for dispatch lineage management.

  Each dispatch represents a scoped task assignment with an ephemeral API
  key. Dispatches form a tree via `parent_dispatch_id`, and every dispatch
  carries its full `lineage_path` (root → self) for efficient prefix
  comparison queries.
  """

  import Ecto.Query

  require Logger

  alias Ecto.Multi
  alias Loopctl.AdminRepo
  alias Loopctl.AuditChain
  alias Loopctl.Auth
  alias Loopctl.Custody.SignedProfile
  alias Loopctl.Dispatches.Dispatch
  alias Loopctl.HeavyRead
  alias Loopctl.TenantKeys
  alias Loopctl.Tenants

  @max_expires_seconds 14_400
  @default_expires_seconds 3_600

  # Upper bound on the verifier candidate pool fetched per request-review, so the
  # selection never degrades into an unbounded fetch as ephemeral dispatches
  # accumulate with agent fan-out.
  @verifier_pool_limit 500

  # Domain-separation label for the verifier-selection PRF (see `verifier_seed/2`).
  # Versioned so a future change to what the seed binds is a new label rather than a
  # silent reinterpretation of the same key.
  @verifier_seed_domain "loopctl/verifier-selection/v1|"

  @doc """
  Creates a new dispatch with an ephemeral API key.

  The lineage_path is computed as: parent.lineage_path ++ [new_dispatch_id].
  For root dispatches (no parent), lineage_path = [self_id].

  ## Parameters

  - `tenant_id` — the tenant UUID
  - `attrs` — map with:
    - `:parent_dispatch_id` (optional, nil for root)
    - `:role` (required)
    - `:agent_id` (required for non-user roles)
    - `:story_id` (optional)
    - `:expires_in_seconds` (optional, default 3600, max 14400)
  - `opts` — keyword list with `:actor_lineage` for audit logging

  ## Returns

  `{:ok, %{dispatch: Dispatch.t(), raw_key: String.t()}}` or `{:error, reason}`
  """
  @spec create_dispatch(Ecto.UUID.t(), map(), keyword()) ::
          {:ok, %{dispatch: Dispatch.t(), raw_key: String.t()}} | {:error, term()}
  def create_dispatch(tenant_id, attrs, opts \\ []) do
    parsed = parse_dispatch_attrs(attrs)
    do_create_dispatch(tenant_id, parsed, opts)
  end

  defp parse_dispatch_attrs(attrs) do
    expires_in =
      (Map.get(attrs, :expires_in_seconds) || Map.get(attrs, "expires_in_seconds") ||
         @default_expires_seconds)
      |> min(@max_expires_seconds)
      |> max(60)

    now = DateTime.utc_now()

    %{
      parent_id: get_attr(attrs, :parent_dispatch_id),
      role: get_attr(attrs, :role),
      agent_id: get_attr(attrs, :agent_id),
      story_id: get_attr(attrs, :story_id),
      # LCP-1 §9 signed profile: the agent's own public key + algorithm. Absent for
      # a bearer dispatch. `agent_pubkey` is raw bytes; accept hex too for JSON APIs.
      agent_pubkey: normalize_pubkey(get_attr(attrs, :agent_pubkey)),
      alg: get_attr(attrs, :alg),
      # LCP-1 §9.2 owner/parent attestation over the agent key (raw or hex sig) and
      # its conditions string. Required when enrolling an agent key.
      attestation: normalize_sig(get_attr(attrs, :attestation)),
      attestation_conditions: get_attr(attrs, :attestation_conditions) || "",
      expires_at: DateTime.add(now, expires_in, :second),
      now: now
    }
  end

  # Accept either atom or string keys (the JSON API sends strings).
  defp get_attr(attrs, key), do: Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))

  # Accept raw signature bytes as-is and hex-encoded signatures from JSON callers.
  # A raw ed25519 signature is 64 bytes; a hex-encoded one is 128 hex chars. On a
  # decode failure we return an explicit `{:error, :malformed_attestation_encoding}`
  # rather than the original string: an undecodable attestation must be REJECTED at
  # the enrollment boundary with a clear encoding reason, not silently persisted as
  # raw bytes only to resurface later as an opaque `:invalid_signature` at verify
  # time. `fetch_attestation/1` surfaces the marker; `attestation_for_storage/1`
  # keeps it out of the persisted changeset.
  defp normalize_sig(nil), do: nil
  defp normalize_sig(<<_::binary-size(64)>> = raw), do: raw

  defp normalize_sig(hex) when is_binary(hex) do
    case Base.decode16(hex, case: :mixed) do
      {:ok, raw} -> raw
      :error -> {:error, :malformed_attestation_encoding}
    end
  end

  # Accept either a hex-encoded key (the JSON API form) or raw key bytes,
  # disambiguated by LENGTH rather than by "does this parse as hex":
  #
  #   * 64 bytes → the JSON-API hex form of a 32-byte Ed25519 key; hex-decode it.
  #   * anything else (notably a 32-byte value) → treated as raw key bytes as-is.
  #
  # Gating the hex-decode on the 64-byte length removes the former hex-FIRST
  # ambiguity: a raw 32-byte key whose bytes happen to be all hex-ASCII no longer
  # decodes to 16 bytes and gets rejected — a 32-byte value is unambiguously a raw
  # key by length. `Dispatch.validate_signed_profile/1` (and the DB CHECK) still
  # enforce the 32-octet Ed25519 length, so a wrong-length or undecodable key is a
  # clean validation error at enrollment rather than a silent persist.
  defp normalize_pubkey(nil), do: nil

  defp normalize_pubkey(<<_::binary-size(64)>> = hex) do
    case Base.decode16(hex, case: :mixed) do
      {:ok, raw} -> raw
      :error -> hex
    end
  end

  defp normalize_pubkey(value) when is_binary(value), do: value

  defp do_create_dispatch(tenant_id, parsed, opts) do
    %{
      parent_id: parent_id,
      role: raw_role,
      agent_id: agent_id,
      story_id: story_id,
      expires_at: expires_at,
      now: now
    } = parsed

    # Carry the signed-profile fields alongside opts so the multi can enroll the
    # key and record it on the audit chain (LCP-1 §9.1.1) without a wider signature.
    opts =
      Keyword.merge(opts,
        agent_pubkey: parsed.agent_pubkey,
        alg: parsed.alg,
        attestation: parsed.attestation,
        attestation_conditions: parsed.attestation_conditions
      )

    case normalize_role(raw_role) do
      {:error, reason} ->
        {:error, reason}

      role ->
        do_create_dispatch_multi(
          tenant_id,
          parent_id,
          role,
          agent_id,
          story_id,
          expires_at,
          now,
          opts
        )
    end
  end

  defp do_create_dispatch_multi(
         tenant_id,
         parent_id,
         role,
         agent_id,
         story_id,
         expires_at,
         now,
         opts
       ) do
    multi =
      Multi.new()
      |> Multi.run(:resolve_lineage, fn _repo, _changes ->
        resolve_lineage(tenant_id, parent_id)
      end)
      |> Multi.run(:verify_attestation, fn _repo,
                                           %{
                                             resolve_lineage: %{
                                               lineage: parent_lineage,
                                               parent: parent
                                             }
                                           } ->
        # LCP-1 §9.2: enrolling an agent key REQUIRES an owner/parent attestation
        # over that key, verified against a key the operator does not hold — the
        # PARENT's agent key (delegation) or the tenant OWNER key (root). This is
        # what makes the signed profile prevention, not just detection: an operator
        # cannot enroll a usable agent key without an authorizing signature.
        #
        # The parent struct was already loaded by `resolve_lineage`; it is threaded
        # here so `resolve_authorizer` reads the parent's agent_pubkey/alg WITHOUT a
        # second `active_parent` SELECT for the same row.
        verify_enrollment_attestation(tenant_id, parent, parent_lineage, opts)
      end)
      |> Multi.run(:create_dispatch, fn _repo, %{resolve_lineage: %{lineage: parent_lineage}} ->
        dispatch_id = Ecto.UUID.generate()
        lineage_path = parent_lineage ++ [dispatch_id]

        %Dispatch{id: dispatch_id, tenant_id: tenant_id}
        |> Dispatch.changeset(%{
          parent_dispatch_id: parent_id,
          agent_id: agent_id,
          story_id: story_id,
          role: role,
          lineage_path: lineage_path,
          expires_at: expires_at,
          created_at: now,
          agent_pubkey: Keyword.get(opts, :agent_pubkey),
          alg: Keyword.get(opts, :alg),
          attestation:
            enrolled_attestation_for_storage(
              Keyword.get(opts, :agent_pubkey),
              Keyword.get(opts, :attestation)
            ),
          attestation_conditions: Keyword.get(opts, :attestation_conditions)
        })
        |> AdminRepo.insert()
      end)
      |> Multi.run(:mint_key, fn _repo, %{create_dispatch: dispatch} ->
        mint_and_link_key(tenant_id, dispatch, agent_id, expires_at)
      end)
      |> Multi.run(:audit, fn _repo, %{mint_key: %{dispatch: dispatch}} ->
        actor_lineage = Keyword.get(opts, :actor_lineage, [])

        base_payload = %{
          "lineage_path" => dispatch.lineage_path,
          "role" => to_string(dispatch.role),
          "expires_at" => DateTime.to_iso8601(dispatch.expires_at)
        }

        # LCP-1 §9.1.1 enrollment transparency + §9.2 attestation: when this dispatch
        # enrolls an agent public key, record the key (hex), alg, AND the verified
        # owner/parent attestation on the hash-chained, STH-covered audit entry. So
        # an operator can neither mint an agent key invisibly (transparency) nor mint
        # one at all without an authorizing signature (attestation, verified in the
        # `:verify_attestation` Multi step above against a key the operator does not
        # hold). A third party can enumerate every enrolled key from the chain alone
        # and re-verify each enrollment's attestation offline. The action names the
        # enrollment so it is filterable.
        #
        # GUARD: a source-scanning tripwire test (`signed_profile_test.exs`,
        # "attestation-gate coupling") requires that enrollment call
        # `SignedProfile.verify_attestation` whenever any production module gates
        # `verify_claim` — satisfied by the `:verify_attestation` step above.
        {action, payload} =
          if dispatch.agent_pubkey do
            {"dispatch_created_with_agent_key",
             Map.merge(base_payload, %{
               "agent_pubkey" => Base.encode16(dispatch.agent_pubkey, case: :lower),
               "alg" => dispatch.alg,
               "attestation" =>
                 dispatch.attestation && Base.encode16(dispatch.attestation, case: :lower),
               "attestation_conditions" => dispatch.attestation_conditions
             })}
          else
            {"dispatch_created", base_payload}
          end

        AuditChain.append(tenant_id, %{
          action: action,
          actor_lineage: actor_lineage,
          entity_type: "dispatch",
          entity_id: dispatch.id,
          payload: payload
        })
      end)

    case AdminRepo.transaction(multi) do
      {:ok, %{mint_key: %{raw_key: raw_key, dispatch: dispatch}}} ->
        {:ok, %{dispatch: dispatch, raw_key: raw_key}}

      {:error, :resolve_lineage, reason, _} ->
        {:error, reason}

      {:error, _step, reason, _} ->
        {:error, reason}
    end
  end

  @doc "Gets a dispatch by ID, tenant-scoped."
  @spec get_dispatch(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, Dispatch.t()} | {:error, :not_found}
  def get_dispatch(tenant_id, dispatch_id) do
    case AdminRepo.get_by(Dispatch, id: dispatch_id, tenant_id: tenant_id) do
      nil -> {:error, :not_found}
      dispatch -> {:ok, dispatch}
    end
  end

  # One page of the enrollment-transparency listing. Bounded so a single call never
  # materializes the whole `dispatch_created_with_agent_key` history — which grows
  # with SIGNED-DISPATCH count (v2 mints a fresh ephemeral dispatch per task and the
  # audit chain is append-only/immutable), NOT with the distinct-key count. Callers
  # stream the full set by following `meta.next_cursor`, mirroring how the sibling
  # `AuditChain.verify_chain/1` keyset-pages the same table instead of one unbounded
  # whole-chain read that would trip the HeavyRead statement timeout or balloon the
  # BEAM heap exactly on the tenant with the most keys to audit.
  @enrolled_keys_default_limit 100
  @enrolled_keys_max_limit 1_000

  @doc """
  Enumerates the agent public keys enrolled under a tenant, **from the audit chain
  alone** (LCP-1 §9.1.1 enrollment transparency), one keyset-paged page at a time.

  This deliberately reads the hash-chained, STH-covered `audit_chain` rather than
  the `dispatches` table: the whole point of enrollment transparency is that a
  tenant can reconstruct the enrolled-key set from the tamper-evident log without
  trusting a mutable server-side listing. Each entry is a
  `dispatch_created_with_agent_key` action carrying `agent_pubkey` (hex) and `alg`.

  ## Pagination

  `opts`:
    * `:limit` — page size (default #{@enrolled_keys_default_limit}, max
      #{@enrolled_keys_max_limit}).
    * `:cursor` — the `chain_position` returned as `meta.next_cursor` on the prior
      page; omit for the first (newest) page.

  Returns `%{data: [row], meta: %{limit:, has_more:, next_cursor:}}` ordered newest
  first, where each `row` is
  `%{agent_pubkey_hex:, alg:, dispatch_id:, lineage_path:, at:, chain_position:,
  integrity_ok:}`. A tenant compares the union of pages against the keys it
  generated; any excess is an operator-minted key.

  ## Tamper-evidence — required companion checks

  `integrity_ok` recomputes each entry's leaf hash from its stored content
  (`AuditChain.entry_hash_valid?/1`, LCP-1 §8.5): a `false` means THIS row's payload
  (e.g. its `agent_pubkey` hex) was altered. Per-row content integrity is NOT the
  whole guarantee, though — to detect a REMOVED enrollment (completeness) the caller
  MUST additionally run `AuditChain.verify_chain/1` and cross-check the chain length
  against the latest Signed Tree Head. This function reports content integrity per
  page; it does not, on its own, prove the set is complete.
  """
  @spec enrolled_agent_keys(Ecto.UUID.t(), keyword()) :: %{data: [map()], meta: map()}
  def enrolled_agent_keys(tenant_id, opts \\ []) do
    limit =
      opts
      |> Keyword.get(:limit, @enrolled_keys_default_limit)
      |> max(1)
      |> min(@enrolled_keys_max_limit)

    base =
      from(e in AuditChain.Entry,
        where: e.tenant_id == ^tenant_id and e.action == "dispatch_created_with_agent_key",
        order_by: [desc: e.chain_position],
        # Fetch one extra row to learn whether a further page exists without a count.
        limit: ^(limit + 1)
      )

    query =
      case Keyword.get(opts, :cursor) do
        nil -> base
        pos when is_integer(pos) -> from(e in base, where: e.chain_position < ^pos)
      end

    # Route each bounded page through the timed `HeavyRead` facade (the explicit
    # `tenant_id` predicate satisfies its structural guard) rather than the tiny
    # 3-connection AdminRepo pool, consistent with how `AuditChain` routes its other
    # audit-chain enumeration reads.
    rows = HeavyRead.all(tenant_id, query, HeavyRead.opts(:enumeration))
    {page, has_more} = split_page(rows, limit)
    next_cursor = if has_more, do: List.last(page).chain_position

    %{
      data: Enum.map(page, &enrolled_key_row/1),
      meta: %{
        limit: limit,
        has_more: has_more,
        next_cursor: next_cursor,
        # Per-row `integrity_ok` proves each entry's CONTENT is unaltered, but NOT
        # that the set is COMPLETE: a REMOVED enrollment is only detectable by
        # verifying the whole chain and cross-checking its length against the latest
        # Signed Tree Head. Surface that to the API consumer so it does not mistake
        # per-row integrity for a completeness proof (LCP-1 §9.1.1 / §8.5).
        completeness: %{
          note:
            "Per-row integrity_ok is content-integrity only; it does NOT prove the " <>
              "enrollment set is complete. To detect a removed enrollment, verify " <>
              "the audit chain (AuditChain.verify_chain/1) and cross-check its " <>
              "length against the latest Signed Tree Head.",
          latest_sth_endpoint: "/api/v1/audit/sth/{tenant_id}",
          inclusion_proof_endpoint: "/api/v1/audit/sth/{tenant_id}/inclusion/{position}"
        }
      }
    }
  end

  defp split_page(rows, limit) do
    if length(rows) > limit, do: {Enum.take(rows, limit), true}, else: {rows, false}
  end

  defp enrolled_key_row(%AuditChain.Entry{} = e) do
    %{
      agent_pubkey_hex: e.payload["agent_pubkey"],
      alg: e.payload["alg"],
      dispatch_id: e.entity_id,
      lineage_path: e.payload["lineage_path"],
      at: e.inserted_at,
      chain_position: e.chain_position,
      integrity_ok: AuditChain.entry_hash_valid?(e)
    }
  end

  @doc "Lists dispatches with optional filters."
  @spec list_dispatches(Ecto.UUID.t(), keyword()) :: %{data: [Dispatch.t()], meta: map()}
  def list_dispatches(tenant_id, opts \\ []) do
    limit = opts |> Keyword.get(:limit, 50) |> max(1) |> min(100)
    offset = opts |> Keyword.get(:offset, 0) |> max(0)

    base =
      from(d in Dispatch,
        where: d.tenant_id == ^tenant_id,
        order_by: [desc: d.created_at]
      )

    base =
      case Keyword.get(opts, :role) do
        nil -> base
        role -> from(d in base, where: d.role == ^role)
      end

    base =
      if Keyword.get(opts, :active_only, false) do
        now = DateTime.utc_now()

        from(d in base,
          where: is_nil(d.revoked_at) and d.expires_at > ^now
        )
      else
        base
      end

    total_count = AdminRepo.aggregate(base, :count, :id)
    data = base |> limit(^limit) |> offset(^offset) |> AdminRepo.all()

    %{data: data, meta: %{total_count: total_count, limit: limit, offset: offset}}
  end

  @doc """
  Revokes a dispatch and all its descendants.
  """
  @spec revoke(Ecto.UUID.t(), Ecto.UUID.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def revoke(tenant_id, dispatch_id) do
    alias Loopctl.Auth.ApiKey
    now = DateTime.utc_now()

    # Find all dispatches to revoke (target + descendants)
    dispatches_query =
      from(d in Dispatch,
        where:
          d.tenant_id == ^tenant_id and
            is_nil(d.revoked_at) and
            (d.id == ^dispatch_id or ^dispatch_id in d.lineage_path),
        select: %{id: d.id, api_key_id: d.api_key_id}
      )

    to_revoke = AdminRepo.all(dispatches_query)
    dispatch_ids = Enum.map(to_revoke, & &1.id)
    key_ids = to_revoke |> Enum.map(& &1.api_key_id) |> Enum.reject(&is_nil/1)

    # Revoke dispatches and their linked api_keys atomically
    multi =
      Multi.new()
      |> Multi.run(:revoke_dispatches, fn _repo, _ ->
        {count, _} =
          from(d in Dispatch, where: d.id in ^dispatch_ids)
          |> AdminRepo.update_all(set: [revoked_at: now])

        {:ok, count}
      end)
      |> Multi.run(:revoke_keys, fn _repo, _ ->
        if key_ids != [] do
          # Select the revoked key_hashes back in the SAME update statement so the
          # post-commit cache invalidation needs no second AdminRepo lookup on the
          # very 3-connection pool this cache exists to relieve (US-33.3, finding-4).
          {_count, key_hashes} =
            from(k in ApiKey,
              where: k.id in ^key_ids and is_nil(k.revoked_at),
              select: k.key_hash
            )
            |> AdminRepo.update_all(set: [revoked_at: now])

          {:ok, key_hashes}
        else
          {:ok, []}
        end
      end)

    case AdminRepo.transaction(multi) do
      {:ok, %{revoke_dispatches: count, revoke_keys: key_hashes}} ->
        # SECURITY (AC-33.3.2): the update_all cascade bypasses changesets, so bust
        # the api-key cache explicitly for every revoked key_hash AFTER commit. The
        # hashes came back from the revoke statement itself (no extra round-trip).
        Loopctl.Auth.invalidate_key_cache_by_hashes(key_hashes)
        {:ok, count}

      {:error, _step, reason, _} ->
        {:error, reason}
    end
  end

  @doc """
  Returns the lineage path of the (non-revoked) dispatch that minted `api_key_id`.

  This is the server-side way to learn the CALLER's lineage: it is derived from
  the key the request authenticated with, never taken from client input. Returns
  `[]` when the key was not minted by a dispatch (legacy env-var keys) or the
  dispatch is revoked — `[]` is inert for `lineage_shares_prefix?/2`, so callers
  fall back to their agent-id checks rather than short-circuiting them.
  """
  @spec lineage_for_api_key(Ecto.UUID.t(), Ecto.UUID.t() | nil) :: [Ecto.UUID.t()]
  def lineage_for_api_key(_tenant_id, nil), do: []

  def lineage_for_api_key(tenant_id, api_key_id) do
    from(d in Dispatch,
      where: d.tenant_id == ^tenant_id and d.api_key_id == ^api_key_id and is_nil(d.revoked_at),
      select: d.lineage_path,
      limit: 1
    )
    |> AdminRepo.one()
    |> Kernel.||([])
  end

  @doc """
  The lineage path of the dispatch that minted `api_key_id`, REVOKED OR NOT.

  For the lineage CEILING, where the question is "was this principal ever inside a
  lineage", not "is its dispatch live". `lineage_for_api_key/2` answers `[]` for a
  revoked dispatch — inert, which is right for the custody gates but exactly the
  shape the ceiling admits as "may start a root". Returns `[]` only when no dispatch
  minted the key.
  """
  @spec minting_lineage_for_api_key(Ecto.UUID.t(), Ecto.UUID.t() | nil) :: [Ecto.UUID.t()]
  def minting_lineage_for_api_key(_tenant_id, nil), do: []

  def minting_lineage_for_api_key(tenant_id, api_key_id) do
    from(d in Dispatch,
      where: d.tenant_id == ^tenant_id and d.api_key_id == ^api_key_id,
      select: d.lineage_path,
      order_by: [desc: d.created_at],
      limit: 1
    )
    |> AdminRepo.one()
    |> Kernel.||([])
  end

  @doc """
  Resolves the active (non-revoked) dispatch that minted an API key, tenant-scoped.

  Server-side identity resolution for LCP-1 §9.3 signed-profile enforcement: the
  caller's enrolled `agent_pubkey`/`alg` live on this row, derived from the key the
  request authenticated with, never from client input. Returns `{:ok, dispatch}`,
  or `:none` when the key was not minted by a dispatch (legacy env-var key) or its
  dispatch is revoked — a bearer caller with no signed identity.
  """
  @spec dispatch_for_api_key(Ecto.UUID.t(), Ecto.UUID.t() | nil) :: {:ok, Dispatch.t()} | :none
  def dispatch_for_api_key(_tenant_id, nil), do: :none

  def dispatch_for_api_key(tenant_id, api_key_id) do
    from(d in Dispatch,
      where: d.tenant_id == ^tenant_id and d.api_key_id == ^api_key_id and is_nil(d.revoked_at),
      order_by: [desc: d.created_at],
      limit: 1
    )
    |> AdminRepo.one()
    |> case do
      nil -> :none
      dispatch -> {:ok, dispatch}
    end
  end

  @doc """
  True when `agent_id` has ANY active (non-revoked, unexpired) ENROLLED (key-carrying)
  dispatch under the tenant. Used to close the LCP-1 §9.3 per-agent impersonation gap:
  once an agent has opted into signing (an enrolled dispatch), a BEARER dispatch minted
  for the same `agent_id` must not make unsigned custody claims in that agent's name.
  """
  @spec agent_has_enrolled_key?(Ecto.UUID.t(), Ecto.UUID.t() | nil) :: boolean()
  def agent_has_enrolled_key?(_tenant_id, nil), do: false

  def agent_has_enrolled_key?(tenant_id, agent_id) do
    now = DateTime.utc_now()

    from(d in Dispatch,
      where:
        d.tenant_id == ^tenant_id and d.agent_id == ^agent_id and not is_nil(d.agent_pubkey) and
          is_nil(d.revoked_at) and d.expires_at > ^now,
      select: 1,
      limit: 1
    )
    |> AdminRepo.one()
    |> is_integer()
  end

  @doc """
  Checks if two lineage paths share a common ROOT (their first element).

  This is deliberately a shared-root test, not a general prefix test: every
  dispatch descended from the same root dispatch shares element 0, which is what
  "same lineage" means for custody separation. An empty lineage on either side is
  never a match.

  This is the STRICTER of the two comparisons, and it applies where separation can be
  guaranteed BY CONSTRUCTION rather than demanded of an arbitrary caller:
  `select_verifier/3`'s `reject_same_root/2`, which declines to pick a verifier under
  the implementer's root, and `Progress.verify_lineage_separated/4`, which compares the
  verifier dispatch that selection RECORDED. Every CALLER comparison — report,
  review-complete and verify alike — uses `lineage_same_chain?/2`; read the note there
  for why demanding a separate root of the caller locks a single-root tenant out.
  """
  @spec lineage_shares_prefix?(list(), list()) :: boolean()
  def lineage_shares_prefix?([], _), do: false
  def lineage_shares_prefix?(_, []), do: false

  def lineage_shares_prefix?([a | _], [b | _]) when a == b, do: true
  def lineage_shares_prefix?(_, _), do: false

  @doc """
  True when the two dispatches lie on ONE root-to-leaf chain — identical, or one
  an ancestor of the other. Siblings are NOT a match.

  ## Why every CALLER comparison needs this

  The documented dispatch tree puts the implementer and the reviewer side by side
  under one orchestrator, and roots everything at a single operator dispatch:

      root (operator, WebAuthn)
      └── orchestrator dispatch
          ├── implementer dispatch
          └── reviewer dispatch

  Under `lineage_shares_prefix?/2` every pair of dispatches in such a tenant
  matches, so the reviewer counts as the implementer and can never report. That
  was invisible until #621 began recording `implementer_dispatch_id` on the HTTP
  path, which is what made the comparison run at all.

  This test expresses what the report gate actually needs — *you may not report
  work done by yourself, by something you dispatched, or by something that
  dispatched you*:

    * identical lineage (the same dispatch) — blocked;
    * `[r, o]` vs `[r, o, i]` (an orchestrator and the implementer it dispatched)
      — blocked, so a parent cannot rubber-stamp its own sub-agent;
    * `[r, o, i]` vs `[r, o, v]` (two siblings) — allowed: separate dispatches,
      separate ephemeral keys, separate `agent_id`s.

  VERIFY's CALLER comparison uses this too. Demanding a separate ROOT of the
  caller made verify unreachable in the tree drawn above — every dispatch-minted
  key shares the one root, so a single-root tenant had no principal that could
  certify anything. The stricter `lineage_shares_prefix?/2` still governs where
  selection can satisfy it by construction: `select_verifier/3` will not nominate
  a same-root verifier, and the RECORDED verifier is compared at root distance.

  Self-approval is not relaxed either way — the `assigned_agent_id` equality
  check runs IN ADDITION at every gate, and an empty lineage is never a match.
  """
  @spec lineage_same_chain?(list(), list()) :: boolean()
  def lineage_same_chain?([], _), do: false
  def lineage_same_chain?(_, []), do: false

  def lineage_same_chain?(a, b) do
    List.starts_with?(a, b) or List.starts_with?(b, a)
  end

  @doc """
  Selects a verifier dispatch from the eligible pool for a story.

  Eligible dispatches: active, non-expired, non-revoked, in the same tenant,
  whose lineage does NOT share a ROOT with the implementer's lineage.

  Selection is deterministic but unpredictable to the caller: the index is drawn
  from an HMAC keyed by the tenant's audit signing PRIVATE key (`verifier_seed/2`).

  SCALE: the same-lineage rejection is pushed into SQL (compare lineage ROOTS,
  `lineage_path[1]`) and the candidate pool is capped at `@verifier_pool_limit`,
  so this never loads the tenant's whole active-dispatch set into memory on the
  request-review path — that path runs on the deliberately tiny BYPASSRLS admin
  pool. The Elixir `Enum.reject` is kept as a belt-and-braces filter for the rows
  the SQL predicate cannot express (e.g. a NULL/empty lineage_path).

  Returns `{:ok, dispatch}` or:

    * `{:error, :no_independent_root}` — the tenant HAS active dispatches, but every
      one of them descends from the implementer's root. Only the operator key may
      start a tree (`LoopctlWeb.DispatchController`'s lineage ceiling), so a tenant
      that minted ONE root has no principal that can verify: `verify_story/4`
      root-separation 409s every dispatch-minted caller. That is L4 working, not a
      pool miss — it is reported separately so `verifier_needed` names the actual
      remedy (have the operator mint an independently-rooted verifier tree) instead
      of looking like a transient shortage.
    * `{:error, :no_eligible_verifier}` — no active candidate dispatches at all.
    * `{:error, :verifier_seed_unavailable}` — no server-side seed secret can be read
      (see `verifier_seed/2` — that case fails CLOSED rather than selecting).
  """
  @spec select_verifier(Ecto.UUID.t(), Ecto.UUID.t(), [Ecto.UUID.t()]) ::
          {:ok, Dispatch.t()}
          | {:error, :no_eligible_verifier | :no_independent_root | :verifier_seed_unavailable}
  def select_verifier(tenant_id, story_id, implementer_lineage) do
    case verifier_pool(tenant_id, implementer_lineage) do
      {:error, reason} ->
        {:error, reason}

      {:ok, pool} ->
        case verifier_seed(tenant_id, story_id) do
          {:ok, <<index_seed::unsigned-64, _rest::binary>>} ->
            {:ok, Enum.at(pool, rem(index_seed, length(pool)))}

          :error ->
            {:error, :verifier_seed_unavailable}
        end
    end
  end

  # --- Private ---

  # An empty pool has two causes with DIFFERENT remedies, and reporting both as
  # `:no_eligible_verifier` hid the one an operator has to act on: "wait for a
  # dispatch" versus "mint an independently-rooted verifier tree". Distinguish them
  # with one extra COUNT, paid only when the pool came back empty.
  defp verifier_pool(tenant_id, implementer_lineage) do
    case candidate_query(tenant_id)
         |> reject_same_root(implementer_lineage)
         |> AdminRepo.all()
         |> Enum.reject(&lineage_shares_prefix?(&1.lineage_path, implementer_lineage)) do
      [] ->
        any_candidate? =
          candidate_query(tenant_id)
          |> exclude(:order_by)
          |> exclude(:limit)
          |> AdminRepo.exists?()

        if any_candidate?,
          do: {:error, :no_independent_root},
          else: {:error, :no_eligible_verifier}

      pool ->
        {:ok, pool}
    end
  end

  defp candidate_query(tenant_id) do
    now = DateTime.utc_now()

    from(d in Dispatch,
      where:
        d.tenant_id == ^tenant_id and
          is_nil(d.revoked_at) and
          d.expires_at > ^now and
          d.role in [:orchestrator, :agent],
      order_by: [asc: d.created_at],
      limit: @verifier_pool_limit
    )
  end

  # The selection index MUST NOT be derivable by the principals it selects between.
  # The candidate pool is enumerable by any agent key (GET /api/v1/dispatches), so
  # everything except the seed key is already known to a caller; the seed is the
  # only secret standing between "deterministic" and "predictable". It is therefore
  # keyed by the tenant's audit signing PRIVATE key — held in the secret store and
  # reachable only server-side (`TenantKeys`, ETS-cached) — never by the audit
  # signing PUBLIC key, which is served unauthenticated on the discovery endpoint.
  #
  # Domain-separated and bound to (tenant, story) so a seed can serve no other
  # purpose and cannot be carried between stories or tenants.
  #
  # FAILS CLOSED. A tenant with no audit key (pre-v2) or an unreachable secret store
  # yields no seed, and there is no public value to fall back to that would not
  # reinstate predictability — so no verifier is selected and the caller flags the
  # story instead (see `Progress.assign_rotating_verifier/3`). Selecting with a
  # guessable seed would be worse than selecting nobody: the verify gate still
  # enforces lineage separation either way.
  defp verifier_seed(tenant_id, story_id) do
    case TenantKeys.get_private_key(tenant_id) do
      {:ok, key} when is_binary(key) and byte_size(key) > 0 ->
        {:ok,
         :crypto.mac(
           :hmac,
           :sha256,
           key,
           @verifier_seed_domain <> tenant_id <> story_id
         )}

      other ->
        Logger.error(
          "verifier_seed_unavailable: no server-side seed secret for tenant=#{tenant_id} " <>
            "story=#{story_id} (#{inspect(other)}). Verifier selection fails closed; the " <>
            "story is flagged verifier_needed. Provision the tenant's audit signing key."
        )

        # A secret-store outage makes this fire on EVERY request-review, deployment-wide,
        # and the only other trace is a log line. Emit a counter so the state is alertable
        # rather than something an operator discovers from unverifiable stories later.
        :telemetry.execute(
          [:loopctl, :custody, :verifier_seed_unavailable],
          %{count: 1},
          %{tenant_id: tenant_id, story_id: story_id}
        )

        :error
    end
  end

  # SQL half of the same-lineage rejection: drop every candidate whose lineage
  # ROOT equals the implementer's root. With an empty implementer lineage there
  # is nothing to reject (the caller's Enum.reject is likewise inert) — see the
  # `select_verifier/3` doc and the chain-of-custody skill's L4 section.
  defp reject_same_root(query, []), do: query

  defp reject_same_root(query, [root | _]) do
    # `type(^root, Ecto.UUID)` is load-bearing: a bare `^root` inside a fragment
    # comparison carries no type, so Postgrex received the 36-char string for a
    # uuid[] element and raised — which meant this branch crashed for EVERY story
    # that had an implementer dispatch (the only way to reach it with a non-empty
    # lineage).
    from(d in query,
      where:
        is_nil(fragment("?[1]", d.lineage_path)) or
          fragment("?[1]", d.lineage_path) != type(^root, Ecto.UUID)
    )
  end

  defp mint_and_link_key(tenant_id, dispatch, agent_id, expires_at) do
    key_attrs = %{
      tenant_id: tenant_id,
      name: "dispatch-#{dispatch.id}",
      role: dispatch.role,
      agent_id: agent_id,
      expires_at: expires_at
    }

    with {:ok, {raw_key, api_key}} <- Auth.generate_api_key(key_attrs),
         {:ok, updated} <-
           dispatch
           |> Dispatch.changeset(%{api_key_id: api_key.id})
           |> AdminRepo.update() do
      {:ok, %{raw_key: raw_key, dispatch: updated}}
    end
  end

  # Returns `{:ok, %{lineage: [uuid], parent: Dispatch.t() | nil}}` so the already-
  # loaded parent row is threaded to `resolve_authorizer` (no redundant re-query).
  defp resolve_lineage(_tenant_id, nil), do: {:ok, %{lineage: [], parent: nil}}

  defp resolve_lineage(tenant_id, parent_id) do
    case active_parent(tenant_id, parent_id) do
      nil -> {:error, :parent_not_found}
      parent -> {:ok, %{lineage: parent.lineage_path, parent: parent}}
    end
  end

  # Fetch a parent dispatch only if it is still an ACTIVE delegator: same tenant,
  # not revoked, not expired. Cascade revocation (US-26.2.1) neutralizes a
  # compromised key; enrollment must therefore fail closed when the delegator is
  # revoked or expired, so a holder of a revoked parent's private key cannot mint
  # NEW enrolled children through the context function. `create_dispatch` is the
  # security boundary — it must enforce this itself and not lean on the controller's
  # pre-check (which only guards the DIRECT parent).
  defp active_parent(tenant_id, parent_id) do
    now = DateTime.utc_now()

    from(d in Dispatch,
      where:
        d.id == ^parent_id and d.tenant_id == ^tenant_id and
          is_nil(d.revoked_at) and d.expires_at > ^now
    )
    |> AdminRepo.one()
  end

  defp normalize_role(role) when role in [:agent, :orchestrator, :user], do: role
  defp normalize_role("agent"), do: :agent
  defp normalize_role("orchestrator"), do: :orchestrator
  defp normalize_role("user"), do: :user
  defp normalize_role(invalid), do: {:error, {:invalid_role, invalid}}

  # LCP-1 §9.2: verify the owner/parent attestation over an enrolled agent key.
  # Returns {:ok, _} for the Multi, or {:error, reason} to roll the enrollment back.
  #
  # A bearer dispatch (no agent_pubkey) needs no attestation. When a key IS present,
  # the attestation is verified against a key the OPERATOR does not hold:
  #
  #   * child (parent is itself enrolled) → the PARENT's agent key signs, over the
  #     PARENT's lineage. Delegation: a parent authorizes its children.
  #   * root (no parent, or a bearer parent) → the tenant OWNER key signs, over the
  #     empty/parent lineage. The owner key's private half is owner-held (§9.2), so
  #     the operator cannot mint the root attestation.
  #
  # The authorizer signs the AUTHORIZER's lineage (`parent_lineage`), which is known
  # in advance — the new dispatch's server-generated id is NOT in the preimage, so
  # the attestation is signable before enrollment.
  defp verify_enrollment_attestation(tenant_id, parent, parent_lineage, opts) do
    case Keyword.get(opts, :agent_pubkey) do
      nil ->
        {:ok, :bearer}

      agent_pubkey ->
        with {:ok, sig} <- fetch_attestation(opts),
             {:ok, authorizer} <- resolve_authorizer(tenant_id, parent) do
          verify_attestation_sig(tenant_id, agent_pubkey, authorizer, parent_lineage, opts, sig)
        end
    end
  end

  defp fetch_attestation(opts) do
    case Keyword.get(opts, :attestation) do
      sig when is_binary(sig) -> {:ok, sig}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :attestation_required}
    end
  end

  # Only persist the attestation on an ENROLLED (key-carrying) dispatch. A bearer
  # dispatch (no agent_pubkey) has nothing to attest — verify_enrollment_attestation
  # short-circuits to `{:ok, :bearer}` WITHOUT verifying any signature — so a
  # caller-supplied attestation there is meaningless and must not be persisted as an
  # unverified blob that could later be mistaken for a verified enrollment record.
  defp enrolled_attestation_for_storage(nil, _sig), do: nil
  defp enrolled_attestation_for_storage(_agent_pubkey, sig), do: attestation_for_storage(sig)

  # Only a real (binary) attestation is persisted. A malformed-encoding marker or a
  # nil (bearer dispatch) never reaches the `:binary` column — a key-carrying
  # dispatch with a malformed attestation has already rolled the enrollment back at
  # the `:verify_attestation` step.
  defp attestation_for_storage(sig) when is_binary(sig), do: sig
  defp attestation_for_storage(_), do: nil

  # Authorizer = the parent's agent key if the parent is an ACTIVE enrolled
  # delegator; otherwise the tenant owner key (root of trust). Fails closed if a
  # root enrollment is attempted with no owner key registered. A revoked or expired
  # parent is treated as absent here (see `active_parent/2`) — but it never reaches
  # this step in practice because `resolve_lineage/2` runs first in the Multi and
  # already fails the whole enrollment closed on a non-active parent.
  defp resolve_authorizer(tenant_id, parent) do
    case parent do
      %Dispatch{agent_pubkey: pk, alg: alg} when is_binary(pk) ->
        {:ok, {pk, alg}}

      _ ->
        case Tenants.custody_owner_key(tenant_id) do
          {pk, alg} -> {:ok, {pk, alg}}
          :none -> {:error, :owner_key_not_registered}
        end
    end
  end

  defp verify_attestation_sig(
         tenant_id,
         agent_pubkey,
         {authorizer_pk, authorizer_alg},
         lineage,
         opts,
         sig
       ) do
    alg = Keyword.get(opts, :alg)

    if alg != authorizer_alg do
      {:error, :attestation_alg_mismatch}
    else
      case SignedProfile.verify_attestation(
             alg: alg,
             tenant_id: tenant_id,
             agent_pubkey: agent_pubkey,
             authorizer_pubkey: authorizer_pk,
             lineage_path: lineage,
             conditions: Keyword.get(opts, :attestation_conditions, ""),
             signature: sig
           ) do
        :ok -> {:ok, :attested}
        {:error, reason} -> {:error, {:attestation_invalid, reason}}
      end
    end
  end
end
