defmodule Loopctl.Knowledge.BulkDeleteToken do
  @moduledoc """
  Schema for the `knowledge_bulk_delete_tokens` table (US-27.12).

  A bulk-delete token is the integrity-protected, server-minted, single-use,
  TTL-bounded handle that makes a high-blast-radius bulk op TOCTOU-safe. It is
  also the PROPOSAL an agent replays: the destructive surface never takes a
  model-visible `confirm`/`approved` argument, because that is authorization the
  caller writes for itself (#779). Two ops mint one — the irreversible HARD
  delete over any selector, and the soft ARCHIVE of a `tag` selector — and the
  `type` column keeps them apart.

  The dry-run (`Loopctl.Knowledge.BulkOps.preview/4`) resolves the selector to a
  bounded id-set and freezes it into this row. The token `id`
  IS the secret — a binary UUID minted by the server and returned to the client;
  it is NEVER trusted from the client (so a forged token can't target a different
  in-tenant id-set, and the row's `tenant_id` guards tenant isolation via explicit
  predicates). The real run (`delete_with_token/3`) loads the row by
  `(id AND tenant_id)`, refuses it if missing/expired/used, stamps `used_at`
  (single-use), and deletes exactly the FROZEN `article_ids` — never whatever the
  original selector matches at execution time.

  ## Tenant isolation (NOT via RLS here)

  Every query against this table runs on `Loopctl.AdminRepo`, which uses a
  BYPASSRLS role — so the table's RLS policy is **never evaluated** on this
  path and does NOT act as a backstop. Tenant isolation rests SOLELY on the
  explicit `t.tenant_id == ^tenant_id` predicates in `Loopctl.Knowledge.BulkOps`
  (token consume, nonce consume, cleanup). The migration still `ENABLE`s an RLS
  policy for defense-in-depth and any future RLS-repo use, but it is inert for
  the AdminRepo-only access this schema is designed for.

  ## Fields

  - `id`          -- binary UUID primary key; the bearer secret
  - `tenant_id`   -- FK to tenants (set programmatically, never cast)
  - `type`        -- WHICH op this proposal authorizes, and the reason a proposal for
    one op can never be replayed as another: `"frozen_token"` (frozen-set HARD
    delete) / `"reconfirm_nonce"` (its oversized replay blocker), and
    `"soft_tag_token"` (frozen-set SOFT archive of a `tag` selector, #779) /
    `"soft_reconfirm_nonce"` (its oversized form). Every consume query in
    `Loopctl.Knowledge.BulkOps` filters on this column; without that predicate a
    consume reads "any unused token row in this tenant" and an archive proposal
    becomes spendable as an irreversible delete of the same set.
  - `article_ids` -- the frozen, size-bounded id-set the delete will operate on
  - `expires_at`  -- TTL boundary; a token past this is refused
  - `used_at`     -- single-use stamp; non-nil ⇒ already consumed, refused
  - `inserted_at` -- creation timestamp (no `updated_at`)
  """

  use Loopctl.Schema

  @type t :: %__MODULE__{}

  schema "knowledge_bulk_delete_tokens" do
    tenant_field()

    field :type, :string, default: "frozen_token"
    field :article_ids, {:array, :binary_id}, default: []
    field :expires_at, :utc_datetime_usec
    field :used_at, :utc_datetime_usec

    timestamps(updated_at: false)
  end

  @cast_fields [:type, :article_ids, :expires_at]

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
