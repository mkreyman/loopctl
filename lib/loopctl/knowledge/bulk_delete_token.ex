defmodule Loopctl.Knowledge.BulkDeleteToken do
  @moduledoc """
  Schema for the `knowledge_bulk_delete_tokens` table (US-27.12).

  A bulk-delete token is the integrity-protected, server-minted, single-use,
  TTL-bounded handle that makes the irreversible bulk HARD-delete TOCTOU-safe.

  The dry-run (`Loopctl.Knowledge.BulkOps.preview/4` with op `:delete`) resolves
  the selector to a bounded id-set and freezes it into this row. The token `id`
  IS the secret — a binary UUID minted by the server and returned to the client;
  it is NEVER trusted from the client (so a forged token can't target a different
  in-tenant id-set, and the row's `tenant_id` plus RLS keep it from touching
  another tenant). The real run (`delete_with_token/3`) loads the row by
  `(id AND tenant_id)`, refuses it if missing/expired/used, stamps `used_at`
  (single-use), and deletes exactly the FROZEN `article_ids` — never whatever the
  original selector matches at execution time.

  ## Fields

  - `id`          -- binary UUID primary key; the bearer secret
  - `tenant_id`   -- FK to tenants (set programmatically, never cast)
  - `article_ids` -- the frozen, size-bounded id-set the delete will operate on
  - `expires_at`  -- TTL boundary; a token past this is refused
  - `used_at`     -- single-use stamp; non-nil ⇒ already consumed, refused
  - `inserted_at` -- creation timestamp (no `updated_at`)
  """

  use Loopctl.Schema

  @type t :: %__MODULE__{}

  schema "knowledge_bulk_delete_tokens" do
    tenant_field()

    field :article_ids, {:array, :binary_id}, default: []
    field :expires_at, :utc_datetime_usec
    field :used_at, :utc_datetime_usec

    timestamps(updated_at: false)
  end

  @cast_fields [:article_ids, :expires_at]

  @doc """
  Changeset for minting a new frozen-set token.

  `tenant_id` is set programmatically and must not appear in attrs.
  """
  @spec create_changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def create_changeset(token \\ %__MODULE__{}, attrs) do
    token
    |> cast(attrs, @cast_fields)
    |> validate_required([:article_ids, :expires_at])
  end
end
