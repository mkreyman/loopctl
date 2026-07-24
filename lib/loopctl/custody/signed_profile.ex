defmodule Loopctl.Custody.SignedProfile do
  @moduledoc """
  LCP-1 §9 `signed`-profile primitives: dispatch attestation and custody-claim
  signatures over agent-held Ed25519 keys.

  In the `bearer` profile the server resolves identity and decides; nothing in the
  record distinguishes a real agent's claim from one the operator fabricated
  (LCP-1 §10.2). The `signed` profile closes that: the AGENT holds its own keypair
  and signs its own claims, so a claim is attributable to the agent keypair rather
  than asserted by the server, and is verifiable offline by a third party.

  This module is the cryptographic core and is deliberately pure — it takes keys,
  messages, and signatures and returns booleans/results. It does NOT read the
  database, decide the deployment profile, or wire into the custody gates; those
  are the caller's concern (see `Loopctl.Dispatches` for enrollment and the
  custody controllers for the pre-gate check). Keeping it pure is what lets the
  same code back the `mix loopctl.spec.vectors` test vectors.

  ## Preimage framing (LCP-1 §1, §9.2, §9.3)

  Every signed message is `SHA-256` of a length-prefixed, domain-separated
  preimage. `LP(x)` is the 64-bit big-endian byte length of `x` followed by `x`.
  Length-prefixing every variable-length field prevents a field-boundary
  ambiguity in which two distinct inputs share a preimage. The `alg` string is
  part of every preimage (LCP-1 §6.1) so that, once a second algorithm exists, a
  signature valid under a weaker one cannot be presented as one under a stronger.
  """

  alias Loopctl.AuditChain.LeafHash

  @attestation_domain "loopctl/dispatch-attestation/1"
  @claim_domain "loopctl/custody-claim/1"
  @owner_rotation_domain "loopctl/owner-key-rotation/2"

  # The only algorithm this version defines (LCP-1 §6.1). A future
  # "secp256k1-schnorr" (Nostr interop) is an ADDITIVE entry here plus a matching
  # verify clause — never a change to an existing preimage.
  @algorithms ["ed25519"]

  @doc "The signature algorithms this version accepts (LCP-1 §6.1)."
  @spec algorithms() :: [String.t()]
  def algorithms, do: @algorithms

  @doc "True when `alg` is an algorithm this version defines."
  @spec known_alg?(term()) :: boolean()
  def known_alg?(alg), do: alg in @algorithms

  # ── Dispatch attestation (LCP-1 §9.2) ─────────────────────────────────────

  @doc """
  The attestation preimage an authorizer signs to enroll an agent key.

  `preimage = domain || LP(alg) || LP(tenant_id) || LP(agent_pubkey) ||
              LP(canonical_json(lineage_path)) || LP(conditions)`

  The attestation authorizes; it does not transfer authorship (LCP-1 §9.2). It is
  authorization *evidence* over the agent's own public key — the agent stays the
  author of anything it later signs.

  ## Replay scope — carry an `expires<...>` condition

  The new dispatch's server-generated id is deliberately EXCLUDED from the preimage
  so the attestation is signable in advance. The consequence is that a single owner
  attestation over key `X` and a given `lineage_path` can be presented to enroll key
  `X` more than once. This is bounded — every enrollment is owner-authorized and
  recorded on the §9.1.1 transparency log, so the operator can attribute nothing to
  a DIFFERENT key and duplicates are detectable — but an owner who wants to bound
  re-enrollment SHOULD scope the attestation with an `expires<unix-ts>` (and/or
  `gate=<name>`) condition. Those conditions are enforced at claim time by
  `conditions_met?/3` (via `Loopctl.Custody.SignedProfilePolicy`), so an expired
  attestation stops authorizing claims once its window passes.
  """
  @spec attestation_preimage(String.t(), binary(), binary(), [binary()], String.t()) :: binary()
  def attestation_preimage(alg, tenant_id, agent_pubkey, lineage_path, conditions)
      when is_binary(alg) and is_binary(tenant_id) and is_binary(agent_pubkey) and
             is_list(lineage_path) and is_binary(conditions) do
    lp(@attestation_domain) <>
      lp(alg) <>
      lp(to_string(tenant_id)) <>
      lp(agent_pubkey) <>
      lp(LeafHash.canonical_json(lineage_path)) <>
      lp(conditions)
  end

  @doc """
  Verifies an owner/authorizer attestation over an agent public key.

  Returns `:ok`, or `{:error, reason}`. Rejects, in order: an unknown `alg`, a
  self-attestation (`authorizer_pubkey == agent_pubkey`, LCP-1 §9.2), malformed
  `conditions` (LCP-1 §9.2 grammar), and finally an invalid signature. Condition
  clauses are NOT evaluated for time here — `expires<...>` is checked against a
  wall clock by the caller (LCP-1 §9.1/§9.3 keep verification clock-independent).
  """
  @spec verify_attestation(keyword()) :: :ok | {:error, atom()}
  def verify_attestation(opts) do
    alg = Keyword.fetch!(opts, :alg)
    tenant_id = Keyword.fetch!(opts, :tenant_id)
    agent_pubkey = Keyword.fetch!(opts, :agent_pubkey)
    authorizer_pubkey = Keyword.fetch!(opts, :authorizer_pubkey)
    lineage_path = Keyword.fetch!(opts, :lineage_path)
    conditions = Keyword.fetch!(opts, :conditions)
    signature = Keyword.fetch!(opts, :signature)

    cond do
      not known_alg?(alg) ->
        {:error, :unknown_alg}

      authorizer_pubkey == agent_pubkey ->
        {:error, :self_attestation}

      not valid_conditions?(conditions) ->
        {:error, :malformed_conditions}

      true ->
        verify_attestation_sig(
          alg,
          tenant_id,
          agent_pubkey,
          lineage_path,
          conditions,
          signature,
          authorizer_pubkey
        )
    end
  end

  # `attestation_preimage/5` calls `canonical_json/1` on `lineage_path`, which
  # RAISES on a malformed term. Rescue it so this pure verify function always
  # honours its `:ok | {:error, atom()}` contract. `preimage_error?/1` (below)
  # enumerates the raises the preimage boundary can produce: a `canonical_json`
  # `ArgumentError` (duplicate-key ambiguity), a `FunctionClauseError` (a
  # wrong-typed arg failing an `attestation_preimage/5` guard, e.g. a non-list
  # `lineage_path`), and a `Protocol.UndefinedError` (`to_string/1` on a value with
  # no `String.Chars`). All collapse to `:malformed_body` rather than a 500.
  defp verify_attestation_sig(
         alg,
         tenant_id,
         agent_pubkey,
         lineage_path,
         conditions,
         signature,
         authorizer_pubkey
       ) do
    preimage = attestation_preimage(alg, tenant_id, agent_pubkey, lineage_path, conditions)

    if verify_sig(alg, preimage, signature, authorizer_pubkey) do
      :ok
    else
      {:error, :invalid_signature}
    end
  rescue
    e -> if preimage_error?(e), do: {:error, :malformed_body}, else: reraise(e, __STACKTRACE__)
  end

  # ── Custody-claim signature (LCP-1 §9.3) ──────────────────────────────────

  @doc """
  The claim preimage an agent signs when submitting a custody claim.

  `preimage = domain || LP(alg) || LP(tenant_id) || LP(gate) || present(work_item_id) ||
              LP(canonical_json(body)) || present(capability_id) || uint64_be(claimed_at)`

  The OPTIONAL fields `work_item_id` and `capability_id` carry an explicit presence
  tag (`present/1`, mirroring `LeafHash`): `0x00` for a nil/absent value, `0x01 ||
  LP(x)` for a present value. Mapping a nil to `LP("")` instead — as a naive `||
  ""` would — makes a nil and a literal empty string collapse to identical bytes,
  reintroducing the field-boundary substitution ambiguity length-prefixing exists
  to prevent.

  `body` is canonicalized with the SAME `canonical_json/1` used for the audit
  leaf, so the signed bytes are stable across map key order and machines.
  """
  @spec claim_preimage(
          String.t(),
          binary(),
          String.t(),
          binary() | nil,
          map(),
          binary() | nil,
          integer()
        ) :: binary()
  def claim_preimage(alg, tenant_id, gate, work_item_id, body, capability_id, claimed_at)
      when is_binary(tenant_id) and is_map(body) and is_integer(claimed_at) do
    # `claimed_at` is encoded as a bare `uint64`; an out-of-range value would
    # silently reduce mod 2^64 and let one signature verify for a different
    # timestamp (audit-binding malleability). Reject rather than wrap. Raised as an
    # ArgumentError so the verify path's rescue maps it to `:malformed_body`.
    if claimed_at < 0 or claimed_at >= 0x1_0000_0000_0000_0000 do
      raise ArgumentError, "claimed_at out of uint64 range"
    end

    # `alg`/`gate` (via `lp/1`) and `work_item_id`/`capability_id` (via `present/1`)
    # raise a FunctionClauseError on a wrong-typed value, which the verify path's
    # rescue maps to `:malformed_body` — so the total contract holds without a wide
    # boolean guard here.

    # `work_item_id`/`capability_id` are guarded to `binary() | nil` so `present/1`
    # receives exactly what it has clauses for. A previous `x && to_string(x)` form
    # mapped a falsy-but-non-nil value (`false`) to `false`, which `present/1` has no
    # clause for and would crash with a FunctionClauseError — escaping the pure
    # `:ok | {:error, atom()}` contract of the verify functions. The guard makes any
    # wrong-typed optional a clean guard failure that `verify_claim_sig/4` rescues.
    lp(@claim_domain) <>
      lp(alg) <>
      lp(to_string(tenant_id)) <>
      lp(gate) <>
      present(work_item_id) <>
      lp(LeafHash.canonical_json(body)) <>
      present(capability_id) <>
      <<claimed_at::unsigned-big-integer-size(64)>>
  end

  @doc """
  Verifies a custody-claim signature against the agent's enrolled public key.

  Returns `:ok` or `{:error, reason}`. A signature proves AUTHORSHIP, not
  timeliness: `claimed_at` is agent-controlled, so a deployment requiring
  freshness MUST enforce it against its own clock independently (LCP-1 §9.3). The
  `alg` MUST match the one recorded on the dispatch (LCP-1 §6.1) — the caller
  passes `dispatch_alg` and this rejects a mismatch, closing the
  algorithm-substitution gap.
  """
  @spec verify_claim(keyword()) :: :ok | {:error, atom()}
  def verify_claim(opts) do
    alg = Keyword.fetch!(opts, :alg)
    dispatch_alg = Keyword.fetch!(opts, :dispatch_alg)
    agent_pubkey = Keyword.fetch!(opts, :agent_pubkey)
    signature = Keyword.fetch!(opts, :signature)

    # `is_nil(agent_pubkey)` is checked BEFORE the alg comparison so an un-enrolled
    # (bearer) dispatch surfaces the accurate `:not_enrolled` reason. If the alg
    # check came first, a bearer dispatch (both `dispatch_alg` and `agent_pubkey`
    # nil, per the both-or-neither DB CHECK) would fall out as `:alg_mismatch` and
    # the `:not_enrolled` clause would be dead.
    cond do
      not known_alg?(alg) -> {:error, :unknown_alg}
      is_nil(agent_pubkey) -> {:error, :not_enrolled}
      alg != dispatch_alg -> {:error, :alg_mismatch}
      true -> verify_claim_sig(opts, alg, agent_pubkey, signature)
    end
  end

  # `claim_preimage/7` calls `canonical_json/1`, which RAISES on a malformed body
  # (a map mixing atom and string keys of the same name), and its guards RAISE a
  # `FunctionClauseError` on a wrong-typed arg (e.g. a non-map `body`). Rescue both
  # via `preimage_error?/1` so this pure verify function always honours its
  # `:ok | {:error, atom()}` contract rather than escaping to internal Elixir callers.
  defp verify_claim_sig(opts, alg, agent_pubkey, signature) do
    preimage =
      claim_preimage(
        alg,
        Keyword.fetch!(opts, :tenant_id),
        Keyword.fetch!(opts, :gate),
        Keyword.fetch!(opts, :work_item_id),
        Keyword.fetch!(opts, :body),
        Keyword.fetch!(opts, :capability_id),
        Keyword.fetch!(opts, :claimed_at)
      )

    if verify_sig(alg, preimage, signature, agent_pubkey) do
      :ok
    else
      {:error, :invalid_signature}
    end
  rescue
    e -> if preimage_error?(e), do: {:error, :malformed_body}, else: reraise(e, __STACKTRACE__)
  end

  # The exceptions the preimage boundary can raise on malformed/wrong-typed input,
  # all mapped to `:malformed_body`. Anything else re-raises — we never want to
  # swallow an unrelated bug behind the verify contract.
  defp preimage_error?(%ArgumentError{}), do: true
  defp preimage_error?(%FunctionClauseError{}), do: true
  defp preimage_error?(%Protocol.UndefinedError{}), do: true
  defp preimage_error?(_), do: false

  # ── Conditions grammar (LCP-1 §9.2) ───────────────────────────────────────

  @doc """
  Validates a `conditions` string per the LCP-1 §9.2 grammar: the empty string, or
  `&`-separated `gate=<name>` / `expires<unix-timestamp>` clauses, ASCII, no
  whitespace, no leading/trailing/double `&`, canonical base-10 timestamps.

  `gate=` is SINGLE-VALUED. `conditions_met?/3` conjuncts every clause, so two
  `gate=` clauses (e.g. `gate=report&gate=verify`) can never both be satisfied by
  one claim's single gate — the attestation would authorize NOTHING for any gate.
  Rather than accept an unusable attestation and let it fail silently at claim
  time, reject more than one `gate=` clause here, at signing/enrollment time.
  """
  @spec valid_conditions?(term()) :: boolean()
  def valid_conditions?(""), do: true

  def valid_conditions?(conditions) when is_binary(conditions) do
    cond do
      String.contains?(conditions, " ") -> false
      String.starts_with?(conditions, "&") -> false
      String.ends_with?(conditions, "&") -> false
      String.contains?(conditions, "&&") -> false
      true -> valid_clauses?(String.split(conditions, "&"))
    end
  end

  def valid_conditions?(_), do: false

  # Every clause must be individually valid AND there may be at most one `gate=`
  # clause — a second one makes the conjunctive `conditions_met?/3` unsatisfiable.
  defp valid_clauses?(clauses) do
    Enum.all?(clauses, &valid_clause?/1) and
      Enum.count(clauses, &String.starts_with?(&1, "gate=")) <= 1
  end

  @doc """
  Evaluates the `conditions` of a verified attestation against a concrete claim.

  Returns `:ok` or `{:error, :condition_unmet}`. `gate=<name>` must equal the
  gate being exercised; `expires<ts>` must be in the future relative to `now`
  (Unix seconds) — the ONE place a wall clock enters, and only the caller's clock,
  never the verifier's storage time. An unparseable clause fails closed.
  """
  @spec conditions_met?(String.t(), String.t(), integer()) :: :ok | {:error, :condition_unmet}
  def conditions_met?("", _gate, _now), do: :ok

  def conditions_met?(conditions, gate, now) when is_binary(conditions) and is_integer(now) do
    conditions
    |> String.split("&")
    |> Enum.reduce_while(:ok, fn clause, :ok ->
      if clause_met?(clause, gate, now),
        do: {:cont, :ok},
        else: {:halt, {:error, :condition_unmet}}
    end)
  end

  defp clause_met?("gate=" <> name, gate, _now), do: name == gate

  defp clause_met?("expires<" <> ts, _gate, now) do
    case Integer.parse(ts) do
      {t, ""} -> now < t
      _ -> false
    end
  end

  defp clause_met?(_unknown, _gate, _now), do: false

  defp valid_clause?("gate=" <> name), do: name != "" and ascii_no_space?(name)

  defp valid_clause?("expires<" <> ts), do: canonical_decimal?(ts)

  defp valid_clause?(_), do: false

  defp canonical_decimal?("0"), do: true
  defp canonical_decimal?(<<d, _::binary>> = s) when d in ?1..?9, do: decimal?(s)
  defp canonical_decimal?(_), do: false

  defp decimal?(s), do: match?({_, ""}, Integer.parse(s)) and not String.contains?(s, "-")

  defp ascii_no_space?(s),
    do: s == for(<<c <- s>>, c > 32 and c < 127, into: "", do: <<c>>)

  # ── Owner-key rotation proof (LCP-1 §9.2 root of trust) ───────────────────

  @doc """
  The preimage the OUTGOING owner key signs to authorize a rotation to a new owner
  key.

  `preimage = LP(domain) || LP(tenant_id) || LP(old_pubkey) || uint64_be(old_set_at) ||
              LP(new_pubkey) || LP(new_alg)`

  Rotating the §9.2 owner key re-roots the entire attestation chain, so a rotation
  MUST prove possession of the retiring root private half — a stolen `:user` API
  key alone cannot re-root trust. First registration (no prior key) is authorized
  by the human-anchor + `:user` gate instead; there is no outgoing key to sign.

  The OUTGOING key (`old_pubkey`) and its `old_set_at` (the Unix second the retiring
  key became current) are bound into the preimage so a captured rotation proof is
  NOT replayable when a prior key becomes current again: after `A→B→A`, key `A`'s
  `set_at` has advanced, so the old `Sign_A(…, A, old_set_at, B)` proof no longer
  matches the reconstructed preimage and cannot re-root trust back to the (now
  compromised) `B`.
  """
  @spec owner_rotation_preimage(binary(), binary(), integer(), binary(), String.t()) :: binary()
  def owner_rotation_preimage(tenant_id, old_pubkey, old_set_at, new_pubkey, new_alg)
      when is_binary(old_pubkey) and is_integer(old_set_at) and is_binary(new_pubkey) and
             is_binary(new_alg) do
    lp(@owner_rotation_domain) <>
      lp(to_string(tenant_id)) <>
      lp(old_pubkey) <>
      <<old_set_at::unsigned-big-integer-size(64)>> <>
      lp(new_pubkey) <>
      lp(new_alg)
  end

  @doc """
  Verifies a raw `signature` over `preimage` under `alg` and `pubkey`.

  Public wrapper over the algorithm-agile signature backend, for callers (e.g.
  owner-key rotation proofs) that build their own domain-separated preimage.
  Returns a boolean; never raises.
  """
  @spec verify(String.t(), binary(), binary(), binary()) :: boolean()
  def verify(alg, preimage, signature, pubkey), do: verify_sig(alg, preimage, signature, pubkey)

  # ── Signature backend (LCP-1 §6.1 algorithm agility) ──────────────────────

  @doc """
  Signs a preimage with an agent/authorizer private key. This is the AGENT-SIDE
  operation — in production the private key never reaches the server (LCP-1 §9.1),
  so this exists as the reference implementation for tests and `mix
  loopctl.spec.vectors`, mirroring how `LeafHash.compute/2` serves both sides.
  Returns the raw signature bytes. Raises on an unknown `alg`.
  """
  @spec sign(String.t(), binary(), binary()) :: binary()
  def sign("ed25519", preimage, private_key) when is_binary(private_key) do
    digest = :crypto.hash(:sha256, preimage)
    :crypto.sign(:eddsa, :none, digest, [private_key, :ed25519])
  end

  def sign(alg, _preimage, _private_key),
    do: raise(ArgumentError, "unknown signature algorithm #{inspect(alg)} (LCP-1 §6.1)")

  # Dispatch on `alg`. Adding "secp256k1-schnorr" later is a new clause here, not
  # a change to any preimage. Every algorithm signs SHA-256(preimage).
  defp verify_sig("ed25519", preimage, signature, pubkey)
       when is_binary(signature) and is_binary(pubkey) do
    digest = :crypto.hash(:sha256, preimage)
    :crypto.verify(:eddsa, :none, digest, signature, [pubkey, :ed25519])
  rescue
    _ -> false
  end

  defp verify_sig(_alg, _preimage, _signature, _pubkey), do: false

  defp lp(bin) when is_binary(bin),
    do: <<byte_size(bin)::unsigned-big-integer-size(64), bin::binary>>

  # Presence tag for an optional field (mirrors `LeafHash.present/1`): 0x00 for an
  # absent (nil) value, 0x01 || LP(x) for a present value. Distinguishes a nil from
  # a present-but-empty string, which `LP("")` alone cannot.
  defp present(nil), do: <<0>>
  defp present(bin) when is_binary(bin), do: <<1>> <> lp(bin)
end
