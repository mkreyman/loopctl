defmodule Loopctl.Coordination.ChannelPost do
  @moduledoc """
  Schema for the `channel_posts` table — the coordination bus (the third memory
  plane: Knowledge = durable, Memory = agent-private, Channel = repo-scoped and
  transient).

  A post is one attributed, short-lived message on a project's coordination
  channel. A **channel is a `project_id`**; sessions on the same repo — across
  machines — read the channel to see what other sessions found, did, or are
  doing. Retention is a uniform 30 days (`expires_at`); there is deliberately
  **no message-type taxonomy** (`:kind`/`:category`/`:type`) — the fleet audit
  showed the category taxonomy was essentially unused. An optional `key` reserves
  a per-(agent, session) working-state slot: in US-39.1 a second write to the same
  `(tenant, project, agent, session, key)` is **rejected** by the partial unique
  index (`{:error, changeset}`), not merged; the `on_conflict` upsert that lets a
  session refresh its own slot lands in US-39.2. The **verified** `agent_id`
  participates in the slot key so a spoofed, client-supplied `session_id` can
  never collide with (US-39.1) — nor, once US-39.2 adds the upsert, overwrite —
  another agent's slot.

  ## Idempotency (US-40.B2)

  Two orthogonal, independent dedup dimensions — never conflate them:

    * **Stable handoff key** (`key`, the working-state slot). A handoff post carries
      a deterministic `key` of the form `handoff:<anchor>` (derived from the
      handoff's durable-home anchor, e.g. `handoff:repo#812`). Because a keyed post
      upserts the caller's own per-`(tenant, project, agent, session, key)` slot, a
      SAME-SESSION re-fire (a retry) refreshes the SAME row — no duplicate. This
      dedups the same-session retry ONLY: a re-fire from a DIFFERENT session
      (offline-reconcile) has a different `session_id` and creates a SEPARATE
      pointer row. At WRITE time that duplicate pointer is tolerated (it is a real,
      independently-attributed row), but the directed-handoff discovery READ
      (`Coordination.directed_handoffs/3`) collapses same-key pointers with
      `DISTINCT ON (key)`, so the pinned set surfaces ONE row per logical handoff —
      the duplicate never inflates the read or its `meta.count`. The
      `handoff:<anchor>` format is a CLIENT-SIDE convention (the /handoff skill) —
      the server does NOT validate it, only treats it as an ordinary slot key. The
      CLAIM (US-40.B1, keyed on `ref`, claimant-independent) — NOT this pointer — is
      the cross-session exactly-once backstop for the WORK.

    * **Client idempotency token** (`idempotency_key`, the KEYLESS append path).
      An OPTIONAL token that makes a KEYLESS write retry-safe: a repeat write with
      the same `(tenant_id, project_id, agent_id, idempotency_key)` returns the
      EXISTING post (`{:ok, post, :deduplicated}`) instead of appending a duplicate
      — the same guarantee `knowledge_create` gives. Enforced by the partial unique
      index `channel_posts_idempotency_uidx WHERE idempotency_key IS NOT NULL AND
      key IS NULL`, caught with `unique_constraint` and resolved to the existing row.
      Scoped to `(tenant, project, agent)` so one agent's token never collides with
      another's. Absent, the write is exactly today's append-only behavior (US-39.2).
      This is a SEPARATE dedup dimension and MUST NEVER be part of the working-state
      slot key (`insert_opts/1` conflict_target) — the token is consulted on the
      KEYLESS path only. That keyless-only invariant is enforced two ways: the index
      predicate carries `AND key IS NULL` (a keyed post never participates in the
      idempotency dimension, so no out-of-scope cross-session keyed dedup), and
      `create_changeset/2` REJECTS (422) a request carrying BOTH a `key` and an
      `idempotency_key` — the combination is nonsensical (the keyed slot already
      dedups a same-session re-fire) and would otherwise silently provide no
      idempotency guarantee.

  ## Trust boundary

  `tenant_id`, `project_id`, `agent_id`, and `expires_at` are set programmatically
  on the struct in `Loopctl.Coordination` — NEVER via `cast/3`. `agent_id` is the
  verified key identity (a caller can never post as another agent); `host` and
  `session_id` are client-supplied, informational, and spoofable — never used for
  authorization or as authoritative attribution.

  `to_host` and `to_capability` (US-40.A5) are the same class: OPTIONAL, freeform,
  client-supplied ADVISORY SURFACING fields that label a post's *intended* target
  (a host or, primarily, a capability such as "fly auth"). They are SPOOFABLE — a
  caller can address a post to ANY host/capability — and are read ONLY as a
  discovery hint (40.C1 directed discovery surfaces "directed-to-me" posts). They
  are NEVER read for authorization, ownership, or any delivery guarantee: they
  gate NOTHING. A post may set neither, either, or both; a post with no addressing
  remains a broadcast visible to EVERYONE on the channel exactly as today. The
  ONLY authorization boundary remains the verified key's tenant (+ after 40.D3,
  project membership).

  ## Isolation

  Runtime isolation is `AdminRepo` (BYPASSRLS) + an explicit `tenant_id` filter in
  every `Loopctl.Coordination` query (the Knowledge/Projects pattern). RLS is
  ENABLED on the table as defense-in-depth — a query missing the tenant filter is
  a bug even though RLS would also stop it.
  """

  use Loopctl.Schema

  require Logger

  alias Loopctl.Coordination.RefsList
  alias Loopctl.Security.SecretDenylist

  @type t :: %__MODULE__{}

  @body_max_length 16_384
  @key_max_length 200
  @session_id_max_length 200
  @host_max_length 255
  @to_capability_max_length 128
  # Bounds the OPTIONAL client idempotency token (US-40.B2), matching the
  # articles' `:string` idempotency_key cap. See the moduledoc idempotency note.
  @idempotency_key_max_length 255

  # `refs` is a bounded, typed-OPEN LIST of reference items
  # `[%{"type" => string, "value" => string, "label" => string?}]` (US-40.A1). The
  # item-COUNT cap is the PRIMARY bound; the serialized-bytes ceiling is secondary.
  #
  #   * <= @refs_max_items (50) items — the primary fan-out/injection bound (do NOT
  #     rely on the byte backstop alone: at ~16KB it caps at an obscure ~32 items
  #     and is an amplifier).
  #   * per item: `type` <= 64 bytes, `value` <= 512 bytes, optional `label` <= 128
  #     bytes — all FREE strings (no key allowlist; `type` is caller-chosen).
  #   * total serialized JSON <= @refs_serialized_max_bytes. Sized for the 50-item
  #     cap: worst case 50 * ({"type":"<=64>","value":"<=512>","label":"<=128>"})
  #     ~= 37KB, so the ceiling is set above that (48KB) to never reject a legit
  #     50-item post while still bounding a pathological payload.
  @ref_type_max_length 64
  @ref_value_max_length 512
  @ref_label_max_length 128
  @refs_max_items 50
  @refs_serialized_max_bytes 49_152

  # The ONLY keys a ref item may carry. Enforced so an item cannot smuggle an extra,
  # UNSCANNED field onto the 30-day cross-session bus (the secret/NUL scan below
  # only walks these three keys).
  @allowed_ref_item_keys ~w(type value label)

  @secret_error_message "must not contain a secret or credential"

  # Text fields that must never carry a NUL byte (Postgres rejects them at insert
  # time with a raw Postgrex.Error/500) nor a denylisted credential shape.
  @scanned_text_fields [
    :body,
    :key,
    :session_id,
    :host,
    :to_host,
    :to_capability,
    :idempotency_key
  ]

  @derive {Jason.Encoder,
           only: [
             :id,
             :tenant_id,
             :project_id,
             :agent_id,
             :session_id,
             :host,
             :to_host,
             :to_capability,
             :key,
             :body,
             :refs,
             :superseded_by,
             :expires_at,
             :inserted_at,
             :updated_at
           ]}

  schema "channel_posts" do
    tenant_field()
    field :project_id, :binary_id
    field :agent_id, :binary_id
    field :session_id, :string
    field :host, :string
    # Advisory, spoofable, surfacing-only addressing (US-40.A5) — NEVER authz.
    field :to_host, :string
    field :to_capability, :string
    field :key, :string
    # OPTIONAL client idempotency token for the KEYLESS write path (US-40.B2).
    # Deliberately NOT in the `@derive Jason.Encoder` `only:` list — the read model
    # stays narrow; the controller builds its own response maps. A SEPARATE dedup
    # dimension from `key`/`session_id` — never part of the working-state slot.
    field :idempotency_key, :string
    field :body, :string
    field :refs, RefsList

    # US-454 (defect 3): supersession terminal state. Set PROGRAMMATICALLY by the
    # context when a later post declares `supersedes: <this post id>` — never
    # castable from caller input (a caller could otherwise self-retire or retire
    # an arbitrary post outside the authorized write path). NULL = live. Directed
    # handoff discovery EXCLUDES superseded posts; the history read marks them.
    field :superseded_by, :binary_id

    # US-454 (defect 1): write-path provenance markers, populated by
    # `Coordination.post/4` so the endpoint can TELL the sender when its write was
    # rescued by a server fallback (handoff key derived from the body, and/or a
    # surrogate session_id minted because the proxy supplied none). Never
    # persisted; nil on every read path.
    field :key_source, :string, virtual: true
    field :session_id_source, :string, virtual: true

    field :expires_at, :utc_datetime_usec

    # DB-generated monotonic sequence (bigserial): strictly increasing with insert
    # order, so newest-first reads can tie-break same-microsecond `inserted_at`
    # values by true insertion order instead of a random v4 `id`. Never cast.
    field :seq, :integer, read_after_writes: true

    timestamps()
  end

  @doc """
  Changeset for creating a channel post.

  Casts ONLY the caller-supplied fields
  `[:session_id, :host, :to_host, :to_capability, :key, :body, :refs]`.
  `tenant_id`, `project_id`, `agent_id`, and `expires_at` are set programmatically
  on the struct by the context and are validated for presence here as a guard
  against a context bug — they are never castable. `to_host`/`to_capability` are
  OPTIONAL, freeform ADVISORY SURFACING fields (spoofable — see the moduledoc
  trust boundary); they gate NOTHING and are validated only for size/NUL/secret
  hygiene like `host`/`session_id`.

  Enforces the size/shape bounds (`body` <= 16KB, `key` <= 200 bytes,
  `session_id` <= 200 bytes, `host` <= 255 bytes, `to_host` <= 255 bytes,
  `to_capability` <= 128 bytes, and a bounded typed-open `refs` LIST — at most
  #{@refs_max_items} items, each `%{"type" => .., "value" => .., "label"? => ..}`
  with per-field byte caps), rejects NUL bytes in every text field AND every
  `refs` item field (Postgres cannot store them — the guard turns a raw 500 into a
  422), and runs the shared secret denylist over `body`, `key`, `session_id`,
  `host`, `to_host`, `to_capability`, and EVERY `refs` item field (`type`,
  `value`, `label`) — a match rejects the write (surfaced as a 422) rather than
  silently dropping the content or leaking a credential onto the shared,
  cross-session-readable channel.

  A blank (`""`/whitespace-only) `body`, `key`, `session_id`, `host`, `to_host`,
  or `to_capability` is
  normalised to `nil` before the required/uniqueness checks: for `body` this
  makes `validate_required/2` reject a whitespace-only post (an effectively empty
  message must not land as noise on the shared, 30-day channel); for `key` it
  means "no keyed slot" rather than occupying the
  `(tenant, project, agent, session, key)` slot with an empty string. A keyed
  post is a per-(agent, session) working-state slot, so `session_id` is required
  whenever `key` is present — without it the partial unique index (which treats a
  NULL `session_id` as distinct) can never dedupe the slot. The DB constraints
  (the session-key partial unique index and the tenant/project/agent foreign
  keys) are declared here so a collision or missing parent surfaces as
  `{:error, changeset}` (422) rather than an unhandled `Ecto.ConstraintError`
  (500).
  """
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(post, attrs) do
    post
    |> cast(attrs, [
      :session_id,
      :host,
      :to_host,
      :to_capability,
      :key,
      :idempotency_key,
      :body,
      :refs
    ])
    |> normalize_blank([
      :body,
      :key,
      :idempotency_key,
      :session_id,
      :host,
      :to_host,
      :to_capability
    ])
    |> validate_required([:tenant_id, :project_id, :agent_id, :body, :expires_at])
    |> validate_length(:body, max: @body_max_length, count: :bytes)
    |> validate_length(:key, max: @key_max_length, count: :bytes)
    |> validate_length(:idempotency_key, max: @idempotency_key_max_length, count: :bytes)
    |> validate_length(:session_id, max: @session_id_max_length, count: :bytes)
    |> validate_length(:host, max: @host_max_length, count: :bytes)
    |> validate_length(:to_host, max: @host_max_length, count: :bytes)
    |> validate_length(:to_capability, max: @to_capability_max_length, count: :bytes)
    |> maybe_require_session_for_key()
    |> validate_key_idempotency_exclusion()
    |> validate_refs()
    |> scan_text_and_refs()
    |> foreign_key_constraint(:tenant_id)
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:agent_id)
    |> unique_constraint(:key,
      name: :channel_posts_session_key_uidx,
      message: "has already been used by this session (working-state slot)"
    )
    |> unique_constraint(:idempotency_key,
      name: :channel_posts_idempotency_uidx,
      message: "has already been used (idempotent keyless write)"
    )
  end

  @doc "Maximum allowed `body` length in bytes."
  @spec body_max_length() :: pos_integer()
  def body_max_length, do: @body_max_length

  @doc "Maximum number of items allowed in the `refs` list."
  @spec refs_max_items() :: pos_integer()
  def refs_max_items, do: @refs_max_items

  # JSON clients routinely send `""` (or whitespace) for an absent field, and in
  # Elixir `""` is truthy — so a blank `key` would force `session_id` to be
  # required AND occupy a real `(tenant, project, agent, session, key)` slot (the
  # partial index keys on `key IS NOT NULL`), colliding on the next blank-key
  # post, and a blank/whitespace `body` would sneak past `validate_required/2` and
  # land as an effectively empty post. Normalise blank/whitespace text to `nil` so
  # `""`/`"   "` means "no value" (required-body rejects it; a keyless post has no
  # slot / spoofable field).
  defp normalize_blank(changeset, fields) do
    Enum.reduce(fields, changeset, &blank_change_to_nil/2)
  end

  defp blank_change_to_nil(field, changeset) do
    case get_change(changeset, field) do
      value when is_binary(value) and value != "" ->
        if String.trim(value) == "", do: put_change(changeset, field, nil), else: changeset

      "" ->
        put_change(changeset, field, nil)

      _ ->
        changeset
    end
  end

  # Scan every persisted text field and every `refs` value for NUL bytes and
  # denylisted credential shapes — over a BOUNDED prefix of each value.
  # `validate_length/3` is non-halting, so without a cap an oversized field would
  # be walked in full by `String.contains?/2` and every denylist regex — a
  # CPU-amplification surface once US-39.2 wires this changeset to an HTTP handler.
  # `scan_slice/1` caps the bytes handed to each scanner at `@scan_byte_cap`,
  # bounding the work to O(@scan_byte_cap) per field regardless of input size (and
  # closing the same amplification path via an oversized `refs` value, which
  # `validate_length` never flags).
  #
  # Scanning is UNCONDITIONAL and PER-FIELD — deliberately NOT gated on a whole-
  # changeset length check. An earlier design skipped ALL scans whenever ANY field
  # had a length error, so a credential in `body` slipped past unscanned merely
  # because an unrelated `host` was oversized — that defeated the operator-visible
  # `secret_blocked` signal and broke the accumulate-every-offending-field contract.
  # Now an over-length field is still rejected on length, AND a credential in its
  # first `@scan_byte_cap` bytes still fires the signal. The only residual gap is a
  # credential padded PAST the cap: rejected on length (no leak) but intentionally
  # invisible to the secret signal — the documented best-effort tradeoff (see
  # `Loopctl.Security.SecretDenylist`).
  defp scan_text_and_refs(changeset) do
    changeset
    |> validate_no_null_bytes()
    |> validate_no_secrets()
  end

  # Cap the bytes handed to the NUL/secret scanners so an oversized field (rejected
  # on length regardless) cannot amplify scan cost. Byte-sliced to match the
  # byte-based length bounds; the denylist regexes are byte-oriented (no `/u`), so a
  # slice landing mid-codepoint is harmless. Every legitimate (within-length) field
  # is <= @scan_byte_cap, so this never truncates a value that will actually land.
  @scan_byte_cap @body_max_length

  defp scan_slice(value) when is_binary(value) and byte_size(value) > @scan_byte_cap,
    do: binary_part(value, 0, @scan_byte_cap)

  defp scan_slice(value), do: value

  # Postgres `text`/`varchar` columns cannot store a NUL byte and raise a raw
  # Postgrex.Error (500) at insert time. JSON permits a NUL byte and Elixir strings
  # accept it, so reject it in the changeset — the caller learns it did not land
  # as a 422, honouring the create_post error contract.
  defp validate_no_null_bytes(changeset) do
    Enum.reduce(@scanned_text_fields, changeset, &reject_null_bytes/2)
  end

  defp reject_null_bytes(field, changeset) do
    value = changeset |> get_field(field) |> scan_slice()

    if is_binary(value) and String.contains?(value, <<0>>) do
      add_error(changeset, field, "must not contain NUL bytes")
    else
      changeset
    end
  end

  # A keyed post occupies a per-(tenant, project, agent, session) working-state
  # slot. The partial unique index includes session_id, and Postgres treats a NULL
  # session_id as distinct — so without a session_id a keyed post can never
  # upsert/dedupe and would accumulate unbounded duplicate rows. Require session_id
  # whenever key is set.
  defp maybe_require_session_for_key(changeset) do
    if get_field(changeset, :key) do
      validate_required(changeset, :session_id)
    else
      changeset
    end
  end

  # The client idempotency token and the keyed working-state slot are two ORTHOGONAL
  # dedup dimensions (see moduledoc): the token is consulted on the KEYLESS path
  # ONLY. A post carrying BOTH a `key` and an `idempotency_key` is nonsensical — the
  # keyed slot already dedups a same-session re-fire, and letting the token ride
  # along a keyed post would either (a) silently provide NO idempotency guarantee
  # (the token column sits inert on a keyed row) or (b), under a bare
  # `idempotency_key IS NOT NULL` index, drag the keyed post into the idempotency
  # dimension and enable OUT-OF-SCOPE cross-session keyed dedup that silently drops a
  # second session's distinct slot write. Reject the combination with an explicit 422
  # so a confused client learns immediately instead of getting a silent no-op (or
  # worse, a dropped write). The scoped partial index (`... AND key IS NULL`) is the
  # storage-layer backstop; this is the primary, user-facing contract. Both fields
  # are already blank-normalized to nil, so this fires only when BOTH are genuinely
  # present.
  defp validate_key_idempotency_exclusion(changeset) do
    if not is_nil(get_field(changeset, :key)) and
         not is_nil(get_field(changeset, :idempotency_key)) do
      add_error(
        changeset,
        :idempotency_key,
        "cannot be combined with a keyed post — the idempotency token applies to the keyless append path only"
      )
    else
      changeset
    end
  end

  # `refs` is a bounded, typed-OPEN LIST (US-40.A1). The `RefsList` custom type has
  # already admitted a list (a non-list scalar 422s as a cast error before this
  # runs); here we enforce the deep invariants and produce SPECIFIC 422 messages.
  # `cond` order: the item-COUNT cap is checked before per-item shape so a 51-item
  # payload fails fast on the primary bound; the shape gate must pass before the NUL
  # scan (which reads item fields); serialized bytes is the secondary ceiling last.
  defp validate_refs(changeset) do
    validate_change(changeset, :refs, fn :refs, refs ->
      cond do
        not is_list(refs) ->
          [refs: "must be a list"]

        length(refs) > @refs_max_items ->
          [refs: "must have at most #{@refs_max_items} items"]

        not Enum.all?(refs, &valid_ref_item?/1) ->
          [
            refs:
              "each item must be a map with a string \"type\" (<=#{@ref_type_max_length} bytes) " <>
                "and \"value\" (<=#{@ref_value_max_length} bytes) and an optional string " <>
                "\"label\" (<=#{@ref_label_max_length} bytes), and no other keys"
          ]

        Enum.any?(refs, &ref_item_has_null_byte?/1) ->
          # jsonb cannot store a NUL ( ) in a string value — Postgres raises a
          # raw Postgrex.Error (500) at insert. Reject it as a 422 here, matching the
          # text-field NUL guard, so no field is a 500 vector.
          [refs: "must not contain NUL bytes"]

        refs_serialized_size(refs) > @refs_serialized_max_bytes ->
          [refs: "serialized size exceeds #{@refs_serialized_max_bytes} bytes"]

        true ->
          []
      end
    end)
  end

  # A valid ref item is a plain map carrying a string `type` and `value` (both
  # required) and an OPTIONAL string `label` — and NO other keys (an extra key would
  # be an unscanned exfil field). Missing `type`/`value`, a non-string field, an
  # over-length field, or an unexpected key all fail → 422.
  defp valid_ref_item?(item) when is_map(item) and not is_struct(item) do
    Map.has_key?(item, "type") and Map.has_key?(item, "value") and
      Enum.all?(Map.keys(item), &(&1 in @allowed_ref_item_keys)) and
      valid_ref_field?(Map.get(item, "type"), @ref_type_max_length) and
      valid_ref_field?(Map.get(item, "value"), @ref_value_max_length) and
      valid_ref_label?(Map.get(item, "label"))
  end

  defp valid_ref_item?(_), do: false

  # `label` is optional: absent (`nil`) is fine, otherwise a bounded string.
  defp valid_ref_label?(nil), do: true
  defp valid_ref_label?(label), do: valid_ref_field?(label, @ref_label_max_length)

  # Byte-based to match the other text bounds (body/key/session_id/host all use
  # `validate_length(count: :bytes)`): a grapheme count would let a value of
  # multibyte chars blow past the intended per-field storage cap.
  defp valid_ref_field?(value, max) when is_binary(value), do: byte_size(value) <= max
  defp valid_ref_field?(_, _), do: false

  # True if ANY of a ref item's scanned fields (`type`/`value`/`label`) contains a
  # NUL byte. Non-map / non-string fields are simply skipped.
  defp ref_item_has_null_byte?(item) when is_map(item) do
    item
    |> Map.take(@allowed_ref_item_keys)
    |> Map.values()
    |> Enum.any?(&(is_binary(&1) and String.contains?(&1, <<0>>)))
  end

  defp ref_item_has_null_byte?(_), do: false

  # Flatten every ref item's scanned string fields (`type`/`value`/`label`) into one
  # list for the secret denylist scan (AC-40.A1.3) — `nil` labels and any non-string
  # values drop out via the `is_binary/1` filter.
  defp flatten_ref_fields(refs) when is_list(refs) do
    Enum.flat_map(refs, fn
      item when is_map(item) ->
        item |> Map.take(@allowed_ref_item_keys) |> Map.values() |> Enum.filter(&is_binary/1)

      _ ->
        []
    end)
  end

  defp flatten_ref_fields(_), do: []

  defp refs_serialized_size(refs) do
    case Jason.encode(refs) do
      {:ok, json} -> byte_size(json)
      # Unencodable refs are already rejected by the key/value checks above; treat
      # an encode failure as over-limit so it can never slip through.
      {:error, _} -> @refs_serialized_max_bytes + 1
    end
  end

  # Scan every persisted, JSON-served field for a credential shape. `session_id`
  # and `host` are client-supplied and echoed to every peer session reading the
  # channel, so they must be scanned too — a Bearer/`sk-`/`lc_` token stuffed into
  # them would otherwise exfiltrate onto the shared bus with no rejection.
  #
  # Errors are ACCUMULATED (not short-circuited) so a caller learns about every
  # offending field in one round trip. A hit emits telemetry + a structured log
  # (no secret value) so an operator can see repeated credential-leak attempts.
  defp validate_no_secrets(changeset) do
    changeset
    |> add_secret_errors(@scanned_text_fields, &(changeset |> get_field(&1) |> scan_slice()))
    |> add_secret_errors([:refs], fn :refs ->
      # Scan EVERY item field — `type`, `value`, AND `label` — not just values
      # (AC-40.A1.3): keys/labels are now attacker-writable, so a secret in a ref
      # `type`/`label` must be rejected exactly as one in `value`. Each field is
      # `scan_slice/1`'d (bounded scan cost) before the denylist walk.
      #
      # Cap the item COUNT at @refs_max_items BEFORE flattening: an over-cap list is
      # already rejected by `validate_refs/1`, so items past the cap never persist
      # and need not be scanned. Without this cap the secret scan walks EVERY item
      # of an arbitrarily long (up to the 2MB-body) list — a per-rejected-request
      # CPU-amplification surface that the item-count cap exists precisely to bound
      # (AC-40.A1.2). `Enum.take/2` on a non-list is a no-op via `cap_refs_for_scan/1`.
      changeset
      |> get_field(:refs)
      |> cap_refs_for_scan()
      |> flatten_ref_fields()
      |> Enum.map(&scan_slice/1)
    end)
  end

  # Bound the fan-out of the secret scan to the same item-count cap the persist path
  # enforces: only the first @refs_max_items items can ever land, so scanning more is
  # wasted work an attacker could weaponise on a rejected request.
  defp cap_refs_for_scan(refs) when is_list(refs), do: Enum.take(refs, @refs_max_items)
  defp cap_refs_for_scan(other), do: other

  defp add_secret_errors(changeset, fields, extractor) do
    Enum.reduce(fields, changeset, fn field, acc ->
      value = extractor.(field)

      has_secret? =
        if is_list(value),
          do: SecretDenylist.any_contains_secret?(value),
          else: SecretDenylist.contains_secret?(value)

      if has_secret? do
        add_error(acc, field, @secret_error_message)
      else
        acc
      end
    end)
  end

  @doc """
  Emits the "credential blocked" security signal (a `:telemetry` event + a
  structured warning) for each field a REJECTED changeset flagged for carrying a
  secret shape.

  The denylist check itself runs (side-effect-free) inside `create_changeset/2`,
  but the signal is fired here — invoked by `Loopctl.Coordination.create_post/4`
  only once, at the point an insert is actually rejected. Keeping the emission out
  of the changeset builder means it fires exactly once per persisted rejection,
  not on every (pure) changeset rebuild, dry-run, or validation preview.
  """
  @spec emit_secret_blocked_events(Ecto.Changeset.t()) :: :ok
  def emit_secret_blocked_events(%Ecto.Changeset{} = changeset) do
    for {field, {msg, _opts}} <- changeset.errors, msg == @secret_error_message do
      emit_secret_blocked(changeset, field)
    end

    :ok
  end

  defp emit_secret_blocked(changeset, field) do
    metadata = %{
      tenant_id: get_field(changeset, :tenant_id),
      project_id: get_field(changeset, :project_id),
      agent_id: get_field(changeset, :agent_id),
      field: field
    }

    :telemetry.execute([:loopctl, :coordination, :secret_blocked], %{count: 1}, metadata)

    Logger.warning(
      "coordination denylist hit: blocked #{field} carrying a credential shape " <>
        "(tenant=#{metadata.tenant_id} project=#{metadata.project_id} agent=#{metadata.agent_id})"
    )

    :ok
  end
end
