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
      through `canonical_json/1` (sorted, string-normalized keys); optional fields
      carry an explicit presence tag. Because keys are normalized to strings and
      sorted on BOTH the write and the read side, and because atoms and their
      string forms encode identically in JSON, a v2 hash reproduces exactly after
      a `jsonb` round-trip — which is what makes §8.5 achievable.

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
        lp(to_string(tenant_id)) <>
        <<position::unsigned-big-integer-size(64)>> <>
        lp(prev_hash) <>
        lp(to_string(action)) <>
        lp(canonical_json(actor_lineage)) <>
        present(entity_type && to_string(entity_type)) <>
        present(entity_id) <>
        lp(canonical_json(payload)) <>
        lp(DateTime.to_iso8601(inserted_at))

    :crypto.hash(:sha256, data)
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
  (Elixir binary comparison is byte-wise). This is what makes a v2 hash stable
  across a `jsonb` round-trip: `%{action: 1}` written and `%{"action" => 1}` read
  back both serialize identically. Scalars use the standard JSON encoding;
  serialization failure raises rather than substituting a placeholder.
  """
  @spec canonical_json(term()) :: binary()
  def canonical_json(value) when is_map(value) and not is_struct(value) do
    inner =
      value
      |> Enum.map(fn {k, v} -> {to_string(k), v} end)
      |> Enum.sort_by(fn {k, _v} -> k end)
      |> Enum.map_join(",", fn {k, v} -> Jason.encode!(k) <> ":" <> canonical_json(v) end)

    "{" <> inner <> "}"
  end

  def canonical_json(value) when is_list(value) do
    "[" <> Enum.map_join(value, ",", &canonical_json/1) <> "]"
  end

  def canonical_json(value), do: Jason.encode!(value)
end
