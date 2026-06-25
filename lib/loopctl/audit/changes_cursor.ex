defmodule Loopctl.Audit.ChangesCursor do
  @moduledoc """
  Integrity-protected, tenant-bound keyset cursor for the change feed (US-27.9b).

  A thin delegator over the shared `Loopctl.KeysetCursor` codec, binding the
  `"changes_cursor"` namespace. All the security-critical logic (HMAC sign/verify,
  constant-time comparison, defensive decode, per-tenant key derivation) lives in
  one place; see `Loopctl.KeysetCursor` for the full trust-model documentation.

  ## Why a keyset cursor (not a since-token)

  The change feed (`GET /api/v1/changes`) paginates audit-log entries in ascending
  time order. The ORIGINAL token was TIMESTAMP-ONLY (`next_since` = the last row's
  `inserted_at`), which is NOT a sound keyset: audit `inserted_at` is
  `utc_datetime_usec` and bulk operations (an `Ecto.Multi` writing several entries,
  or `insert_all`) commit MULTIPLE rows at the SAME microsecond. A page boundary that
  lands mid-tie then either SKIPS the tied rows after the boundary (silent gap) or
  RE-EMITS them (duplicate). Encoding the stable unique tuple `(inserted_at, id)`
  steps PAST a specific row regardless of how many share its timestamp — the same
  tie-break fix the article-list keyset (US-27.9a) introduced.

  ## Namespace separation

  The `"changes_cursor"` namespace separates these cursors from the article
  enumerations' `"article_cursor"`: a change-feed cursor and an article cursor are
  NOT interchangeable even within one tenant — the per-tenant HMAC key folds the
  namespace in, so the signatures differ and a cross-surface replay fails to verify.
  """

  alias Loopctl.KeysetCursor

  @namespace "changes_cursor"

  @typedoc "The keyset position: the `(inserted_at, id)` of an audit row in (inserted_at ASC, id ASC) order."
  @type position :: KeysetCursor.position()

  @doc """
  Encodes the keyset position `{inserted_at, id}` into an opaque, tenant-bound cursor
  string (delegates to `Loopctl.KeysetCursor.encode/3` under the `"changes_cursor"`
  namespace).
  """
  @spec encode(Ecto.UUID.t(), position()) :: String.t()
  def encode(tenant_id, position), do: KeysetCursor.encode(@namespace, tenant_id, position)

  @doc """
  Decodes and verifies an opaque cursor (delegates to `Loopctl.KeysetCursor.decode/3`
  under the `"changes_cursor"` namespace). Returns `{:ok, {inserted_at, id}}` or
  `{:error, :invalid}` — never raises.
  """
  @spec decode(Ecto.UUID.t(), String.t()) :: {:ok, position()} | {:error, :invalid}
  def decode(tenant_id, cursor), do: KeysetCursor.decode(@namespace, tenant_id, cursor)
end
