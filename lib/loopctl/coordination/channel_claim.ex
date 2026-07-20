defmodule Loopctl.Coordination.ChannelClaim do
  @moduledoc """
  Schema for the `channel_claims` table — the exactly-once handoff-claim surface of
  the Repo Coordination Bus (Epic 40, US-40.B1).

  A claim reserves an out-of-band unit of work (a `ref`, e.g. `"handoff:repo#812"`)
  for exactly ONE agent among several racing on the same repo. It is DISTINCT from
  `Loopctl.Coordination.ChannelPost`: a post's per-session slot uniqueness INCLUDES
  the author (`agent_id`), so two agents claiming the same handoff would create two
  distinct slots and never collide. Exactly-once needs uniqueness EXCLUDING the
  claimant — `(tenant_id, project_id, ref)` — so the first inserter wins and every
  loser hits a UNIQUE violation surfaced as `{:error, :already_claimed}` (HTTP 409).

  ## Concurrency

  Claiming is a pure INSERT against the `channel_claims_ref_uidx` unique index —
  NEVER a read-then-insert. Postgres serializes concurrent inserts on the index:
  exactly one commits, the rest raise a unique violation that `unique_constraint/3`
  converts to a changeset error. This has NO TOCTOU window (unlike SELECT-then-
  INSERT), which is precisely why INSERT-to-claim was chosen over a row-lock/upsert
  claim.

  ## Trust boundary

  `tenant_id`, `project_id`, `claimant_agent_id`, `claimed_at`, and
  `lease_expires_at` are set programmatically on the struct in `Loopctl.Coordination`
  — NEVER via `cast/3` (mirroring `ChannelPost`). `claimant_agent_id` is the verified
  key identity, so a caller can never claim as another agent. Only `ref` (and,
  derived server-side, the lease) is caller-influenced.

  ## Isolation

  Runtime isolation is `AdminRepo` (BYPASSRLS) + an explicit `tenant_id` filter in
  every `Loopctl.Coordination` query (the coordination-module convention). RLS is
  ENABLED on the table as defense-in-depth — a query missing the tenant filter is a
  bug even though RLS would also stop it.
  """

  use Loopctl.Schema

  @type t :: %__MODULE__{}

  # A ref names an out-of-band unit of work ("handoff:repo#812"), not a row. Bound
  # its byte length like ChannelPost's other free text fields so it cannot be an
  # index-bloat / amplification vector.
  @ref_max_length 512

  @derive {Jason.Encoder,
           only: [
             :id,
             :tenant_id,
             :project_id,
             :claimant_agent_id,
             :ref,
             :claimed_at,
             :lease_expires_at,
             :done_at,
             :inserted_at,
             :updated_at
           ]}

  schema "channel_claims" do
    tenant_field()
    field :project_id, :binary_id
    field :claimant_agent_id, :binary_id
    field :ref, :string
    field :claimed_at, :utc_datetime_usec
    field :lease_expires_at, :utc_datetime_usec
    field :done_at, :utc_datetime_usec

    timestamps()
  end

  @doc """
  Changeset for creating a claim.

  Casts ONLY `:ref` (the caller-supplied anchor); `tenant_id`, `project_id`,
  `claimant_agent_id`, `claimed_at`, and `lease_expires_at` are set programmatically
  on the struct by the context and are validated here for presence only — they are
  never castable (mirrors `ChannelPost.create_changeset/2`'s trust boundary).

  A blank (`""`/whitespace-only) `ref` is normalised to `nil` so `validate_required`
  rejects it (an empty anchor must never occupy the `(tenant, project, ref)` slot).
  Enforces the `ref` byte cap. Declares the `channel_claims_ref_uidx`
  `unique_constraint` (matching the DB index name) so a concurrent duplicate claim
  surfaces as `{:error, changeset}` — which the context maps to
  `{:error, :already_claimed}` (409) — rather than a raw `Ecto.ConstraintError`
  (500). The `foreign_key_constraint`s turn a missing parent into a 422 too.
  """
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(claim, attrs) do
    claim
    |> cast(attrs, [:ref])
    |> normalize_blank_ref()
    |> validate_required([
      :tenant_id,
      :project_id,
      :claimant_agent_id,
      :ref,
      :claimed_at,
      :lease_expires_at
    ])
    |> validate_length(:ref, max: @ref_max_length, count: :bytes)
    |> validate_no_null_bytes()
    |> foreign_key_constraint(:tenant_id)
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:claimant_agent_id)
    |> unique_constraint(:ref,
      name: :channel_claims_ref_uidx,
      message: "has already been claimed"
    )
  end

  @doc "Maximum allowed `ref` length in bytes."
  @spec ref_max_length() :: pos_integer()
  def ref_max_length, do: @ref_max_length

  # A blank/whitespace ref means "no anchor" — normalise to nil so validate_required
  # rejects it rather than reserving the slot with an empty string.
  defp normalize_blank_ref(changeset) do
    case get_change(changeset, :ref) do
      value when is_binary(value) ->
        if String.trim(value) == "", do: put_change(changeset, :ref, nil), else: changeset

      _ ->
        changeset
    end
  end

  # Postgres `text` cannot store a NUL byte and raises a raw Postgrex.Error (500) at
  # insert. JSON permits it and Elixir strings accept it, so reject it in the
  # changeset — the caller learns it did not land as a 422.
  defp validate_no_null_bytes(changeset) do
    case get_field(changeset, :ref) do
      value when is_binary(value) ->
        if String.contains?(value, <<0>>) do
          add_error(changeset, :ref, "must not contain NUL bytes")
        else
          changeset
        end

      _ ->
        changeset
    end
  end
end
