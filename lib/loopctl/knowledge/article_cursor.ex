defmodule Loopctl.Knowledge.ArticleCursor do
  @moduledoc """
  Integrity-protected, tenant-bound keyset cursor for the article list / index
  enumerations (US-27.9a, US-27.9b).

  A thin delegator over the shared `Loopctl.KeysetCursor` codec, binding the
  `"article_cursor"` namespace. All the security-critical logic (HMAC sign/verify,
  constant-time comparison, defensive decode, per-tenant key derivation) lives in
  one place; see `Loopctl.KeysetCursor` for the full trust-model documentation.

  The `"article_cursor"` namespace separates these cursors from other keyset
  surfaces (e.g. the change feed's `"changes_cursor"`): a cursor minted here cannot
  be replayed against another enumeration, even within the same tenant.
  """

  alias Loopctl.KeysetCursor

  @namespace "article_cursor"

  @typedoc "The keyset position: the `(inserted_at, id)` of a row in (inserted_at ASC, id ASC) order."
  @type position :: KeysetCursor.position()

  @doc """
  Encodes the keyset position `{inserted_at, id}` into an opaque, tenant-bound cursor
  string (delegates to `Loopctl.KeysetCursor.encode/3` under the `"article_cursor"`
  namespace).
  """
  @spec encode(Ecto.UUID.t(), position()) :: String.t()
  def encode(tenant_id, position), do: KeysetCursor.encode(@namespace, tenant_id, position)

  @doc """
  Decodes and verifies an opaque cursor (delegates to `Loopctl.KeysetCursor.decode/3`
  under the `"article_cursor"` namespace). Returns `{:ok, {inserted_at, id}}` or
  `{:error, :invalid}` — never raises.
  """
  @spec decode(Ecto.UUID.t(), String.t()) :: {:ok, position()} | {:error, :invalid}
  def decode(tenant_id, cursor), do: KeysetCursor.decode(@namespace, tenant_id, cursor)
end
