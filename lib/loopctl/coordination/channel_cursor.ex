defmodule Loopctl.Coordination.ChannelCursor do
  @moduledoc """
  Integrity-protected, tenant-bound keyset cursor for the repo Coordination Bus
  channel read (US-40.C2).

  A thin delegator over the shared `Loopctl.KeysetCursor` codec, binding the
  `"channel_cursor"` namespace. All the security-critical logic (HMAC sign/verify,
  constant-time comparison, defensive decode, per-tenant key derivation) lives in
  one place; see `Loopctl.KeysetCursor` for the full trust-model documentation.

  ## Why `(inserted_at, seq)`, not `(inserted_at, id)`

  The channel history read (`GET /api/v1/channel/posts`) pages `channel_posts`
  newest-first. `inserted_at` is `utc_datetime_usec` and same-microsecond ties are
  possible, so a bare-timestamp cursor is not a sound keyset. The obvious tie-break,
  the row `id`, is a RANDOM v4 UUID that carries no insert order — a keyset on
  `(inserted_at, id)` would page non-deterministically across ties (this is why
  US-40.C2 SUPERSEDES US-40.5, which keyset on `id`). The correct tie-break is the
  `seq` BIGSERIAL column (strictly increasing with insert order), so this cursor
  encodes the position `(inserted_at, seq)` — a monotonic INTEGER tiebreak, which
  the shared codec supports alongside the UUID shape.

  ## Namespace separation

  The `"channel_cursor"` namespace separates these cursors from the change feed's
  `"changes_cursor"` and the article enumerations' `"article_cursor"`: the
  per-tenant HMAC key folds the namespace in, so a cursor minted here cannot be
  replayed against another enumeration, even within the same tenant.
  """

  alias Loopctl.KeysetCursor

  @namespace "channel_cursor"

  @typedoc "The keyset position: the `(inserted_at, seq)` of a channel post in (inserted_at DESC, seq DESC) order."
  @type position :: {DateTime.t(), integer()}

  @doc """
  Encodes the keyset position `{inserted_at, seq}` into an opaque, tenant-bound
  cursor string (delegates to `Loopctl.KeysetCursor.encode/3` under the
  `"channel_cursor"` namespace).
  """
  @spec encode(Ecto.UUID.t(), position()) :: String.t()
  def encode(tenant_id, position), do: KeysetCursor.encode(@namespace, tenant_id, position)

  @doc """
  Decodes and verifies an opaque cursor (delegates to `Loopctl.KeysetCursor.decode/3`
  under the `"channel_cursor"` namespace). Returns `{:ok, {inserted_at, seq}}` or
  `{:error, :invalid}` — never raises.
  """
  @spec decode(Ecto.UUID.t(), String.t()) :: {:ok, position()} | {:error, :invalid}
  def decode(tenant_id, cursor), do: KeysetCursor.decode(@namespace, tenant_id, cursor)
end
