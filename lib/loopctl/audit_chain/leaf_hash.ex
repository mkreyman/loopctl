defmodule Loopctl.AuditChain.LeafHash do
  @moduledoc """
  Leaf-hash construction for the per-tenant audit chain, versioned per
  LCP-1 §8 (`docs/spec/LCP-1-custody-claims.md`).

  A leaf hash MUST commit to the content of its own entry, so that a third party
  can recompute it from stored fields and detect tampering (LCP-1 §8.5). Two
  versions exist:

    * **v1** — the original construction (`compute_v1/1`). Kept verbatim so that
      historical entries remain reproducible by the exact algorithm that wrote
      them. It has two defects a verifier MUST know about (LCP-1 §8.1): the JSON
      is not canonicalized, so key order is not stable across the atom-keyed map
      written and the string-keyed map read back from `jsonb`; and fields are
      concatenated without separation. v1 is therefore NOT reliably reproducible
      after a round-trip through storage. It MUST NOT be used for new entries.

    * **v2** — the current construction (`compute_v2/1`, LCP-1 §8.2). Every field
      is length-prefixed and domain-separated; objects and arrays are serialized
      through `canonical_json/1` (sorted, string-normalized keys, decimal-normalized
      numbers); optional fields carry an explicit presence tag. Reproducibility
      after a `jsonb` round-trip is achieved deliberately, by neutralizing the two
      transforms PostgreSQL applies to a stored value: keys are normalized to
      strings and sorted on BOTH the write and the read side (atoms and their
      string forms encode identically), and numbers are normalized to a single
      canonical decimal string so that jsonb's numeric normalization — which
      rewrites exponent/scale forms and decodes an integral float such as `1.0e22`
      back as an Elixir integer — cannot change the preimage. That equivalence is
      what makes §8.5 achievable and is exercised end-to-end in the round-trip
      test; without the number normalization the guarantee would hold only for
      string/integer payloads.

  Serialization failure is a hard error (`Jason.encode!/1` raises); a hash MUST
  never silently substitute an empty value for a payload it failed to serialize
  (LCP-1 §8.2).
  """

  @current_version 2

  @typedoc """
  The field set a leaf hash commits to. `tenant_id` and `entity_id` are the
  string UUID forms; `prev_hash` is the 32 raw bytes; `inserted_at` is a
  microsecond `DateTime`.
  """
  @type fields :: %{
          required(:tenant_id) => binary(),
          required(:position) => non_neg_integer(),
          required(:prev_hash) => binary(),
          required(:action) => atom() | binary(),
          required(:actor_lineage) => list() | map(),
          required(:entity_type) => atom() | binary(),
          required(:entity_id) => binary() | nil,
          required(:payload) => map() | list(),
          required(:inserted_at) => DateTime.t()
        }

  @doc "The leaf-hash version new entries are written with (LCP-1 §8.4)."
  @spec current_version() :: pos_integer()
  def current_version, do: @current_version

  @doc """
  Computes a leaf hash for `fields` using `version` (default: the current
  version). Dispatch on a STORED `hash_version` when recomputing an existing
  entry — never assume the current version (LCP-1 §8.4).
  """
  @spec compute(fields(), pos_integer()) :: binary()
  def compute(fields, version \\ @current_version)
  def compute(fields, 1), do: compute_v1(fields)
  def compute(fields, 2), do: compute_v2(fields)

  # An entry MUST carry a version this module knows how to construct. An unknown
  # version (a future format, or a corrupted/hand-edited `hash_version`) cannot be
  # validated, so a tamper-detection path must fail LOUDLY rather than crash with
  # an opaque FunctionClauseError. The DB CHECK `audit_chain_hash_version_valid`
  # keeps this unreachable for well-formed rows; this clause is the last line.
  def compute(_fields, version) do
    raise ArgumentError,
          "unknown leaf-hash version #{inspect(version)} " <>
            "(LCP-1 §8.4 defines 1 and 2) — refusing to recompute, an unrecognized " <>
            "version cannot be validated and must be treated as invalid"
  end

  # ── v1: original construction, preserved verbatim ─────────────────────────

  defp compute_v1(%{
         tenant_id: tenant_id,
         position: position,
         prev_hash: prev_hash,
         action: action,
         actor_lineage: actor_lineage,
         entity_type: entity_type,
         entity_id: entity_id,
         payload: payload,
         inserted_at: inserted_at
       }) do
    canonical =
      Jason.encode!(%{
        action: action,
        actor_lineage: actor_lineage,
        entity_id: entity_id,
        entity_type: entity_type,
        payload: payload
      })

    data =
      tenant_id <>
        Integer.to_string(position) <>
        prev_hash <>
        canonical <>
        DateTime.to_iso8601(inserted_at)

    :crypto.hash(:sha256, data)
  end

  # ── v2: length-prefixed, domain-separated, canonicalized (LCP-1 §8.2) ──────

  @domain "loopctl/audit-leaf/2"

  defp compute_v2(%{
         tenant_id: tenant_id,
         position: position,
         prev_hash: prev_hash,
         action: action,
         actor_lineage: actor_lineage,
         entity_type: entity_type,
         entity_id: entity_id,
         payload: payload,
         inserted_at: inserted_at
       }) do
    data =
      lp(@domain) <>
        lp(canonical_uuid(tenant_id)) <>
        <<position::unsigned-big-integer-size(64)>> <>
        lp(prev_hash) <>
        lp(to_string(action)) <>
        lp(canonical_json(actor_lineage)) <>
        present(entity_type && to_string(entity_type)) <>
        present(entity_id && canonical_uuid(entity_id)) <>
        lp(canonical_json(payload)) <>
        lp(DateTime.to_iso8601(inserted_at))

    :crypto.hash(:sha256, data)
  end

  # Canonicalize a UUID to its stored 36-char lowercase string form (LCP-1 §8.5).
  # The write-time hash is computed from the RAW attrs a caller passed
  # (`build_entry_attrs`), which may be a non-canonical string (uppercase) or a
  # 16-byte binary; the recompute-time hash reads the value back through
  # `Ecto.UUID`, which stores the canonical lowercase string. Routing both sides
  # through `Ecto.UUID.cast/1` makes the preimage identical regardless of caller
  # input form, so a non-canonical UUID can no longer produce a FALSE tampering
  # positive. A value `Ecto.UUID` cannot cast falls back to `to_string/1`,
  # preserving prior behaviour for non-UUID inputs.
  defp canonical_uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> uuid
      :error -> to_string(value)
    end
  end

  # Length-prefixed encoding: uint64 big-endian length, then the bytes.
  defp lp(bin) when is_binary(bin),
    do: <<byte_size(bin)::unsigned-big-integer-size(64), bin::binary>>

  # Presence tag for an optional field: 0x00 for absent, 0x01 || LP(x) for
  # present. Without it an absent field and a present-but-empty field would
  # produce identical preimages (LCP-1 §8.2).
  defp present(nil), do: <<0>>
  defp present(bin) when is_binary(bin), do: <<1>> <> lp(bin)

  @doc """
  Deterministic JSON serialization with recursively sorted, string-normalized
  object keys (LCP-1 §8.3).

  Object keys are normalized to strings and sorted by their UTF-8 octet sequence
  (Elixir binary comparison is byte-wise), so `%{action: 1}` written and
  `%{"action" => 1}` read back serialize identically.

  Numbers are normalized to a single canonical decimal string via `Decimal`. This
  is required for `jsonb` round-trip stability: PostgreSQL stores every JSON number
  as `numeric`, so an integral float such as `1.0e22` is decoded back as an Elixir
  INTEGER (`10000000000000000000000`), and exponent/trailing-zero forms are
  rewritten. Routing the write-time term and the read-back term through the same
  shortest-decimal → `Decimal.normalize/1` pipeline makes the preimage identical on
  both sides; without it a legitimate float payload would produce a FALSE tampering
  positive in `AuditChain.entry_hash_valid?/1`. Non-numeric scalars use the standard
  JSON encoding; serialization failure raises rather than substituting a placeholder.
  """
  @spec canonical_json(term()) :: binary()
  def canonical_json(value) when is_map(value) and not is_struct(value) do
    normalized = Enum.map(value, fn {k, v} -> {to_string(k), v} end)
    keys = Enum.map(normalized, fn {k, _v} -> k end)

    # A map holding both an atom and a string of the same name (e.g.
    # `%{score: 1, "score" => 2}`) collapses to one key after `to_string/1`, and
    # PostgreSQL `jsonb` deduplicates it on write (last wins) — so a silent emit of
    # duplicate keys would make the recompute disagree with storage and report a
    # FALSE tampering positive. §8.2 requires serialization ambiguity to be a hard
    # error, so raise rather than corrupt the tamper detector (Fable review #4).
    if length(Enum.uniq(keys)) != length(keys) do
      raise ArgumentError,
            "canonical_json: object has duplicate key after string normalization " <>
              "(a map mixing atom and string keys of the same name); refusing to " <>
              "emit an ambiguous preimage"
    end

    inner =
      normalized
      |> Enum.sort_by(fn {k, _v} -> k end)
      |> Enum.map_join(",", fn {k, v} -> Jason.encode!(k) <> ":" <> canonical_json(v) end)

    "{" <> inner <> "}"
  end

  def canonical_json(value) when is_list(value) do
    "[" <> Enum.map_join(value, ",", &canonical_json/1) <> "]"
  end

  # A `%Decimal{}` is NOT a native JSON number to the `:map` storage encoder: the
  # column is dumped with `Jason`, which encodes a Decimal the same way it will be
  # stored, and PostgreSQL returns that stored form on read. Canonicalize it
  # through the identical encode step so the write-time term and the jsonb-decoded
  # read-back term agree — routing it through `canonical_number/1` instead would
  # treat it as a number the storage layer never wrote and yield a FALSE tampering
  # positive on a pristine row (Fable review #1).
  def canonical_json(%Decimal{} = value),
    do: value |> Jason.encode!() |> Jason.decode!() |> canonical_json()

  def canonical_json(value) when is_integer(value), do: canonical_number(value)
  def canonical_json(value) when is_float(value), do: canonical_number(value)
  def canonical_json(value), do: Jason.encode!(value)

  # Canonical decimal string for a native JSON number, identical for a write-time
  # value and the value PostgreSQL hands back after a `jsonb` round-trip. A float
  # goes through its shortest round-trip JSON text (which is exactly what jsonb
  # parses into `numeric`) so that, e.g., a write-side float `1.0e22` and a
  # read-side integer `10000000000000000000000` both normalize to the same string.
  defp canonical_number(value) when is_integer(value),
    do: value |> Decimal.new() |> normalize_decimal()

  defp canonical_number(value) when is_float(value),
    do: value |> Jason.encode!() |> Decimal.new() |> normalize_decimal()

  defp normalize_decimal(%Decimal{} = decimal) do
    normalized = Decimal.normalize(decimal)

    # PostgreSQL `numeric` has no signed zero: `-0.0` is stored and returned as
    # `0`, so a write-side `-0.0` (which normalizes to "-0") must collapse to "0"
    # to match the read-back value, else a pristine row reports as tampered
    # (Fable review #2).
    if Decimal.equal?(normalized, 0) do
      "0"
    else
      Decimal.to_string(normalized, :normal)
    end
  end
end
