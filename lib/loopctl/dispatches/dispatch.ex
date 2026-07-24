defmodule Loopctl.Dispatches.Dispatch do
  @moduledoc """
  Schema for the `dispatches` table.

  Each dispatch represents a scoped task assignment: an orchestrator
  or operator dispatching a sub-agent to work in a specific role,
  optionally on a specific story, with an ephemeral API key.
  """

  use Loopctl.Schema

  @type t :: %__MODULE__{}

  @roles [:agent, :orchestrator, :user]
  @signed_algorithms ["ed25519"]

  schema "dispatches" do
    field :tenant_id, Ecto.UUID
    field :parent_dispatch_id, Ecto.UUID
    field :api_key_id, Ecto.UUID
    field :agent_id, Ecto.UUID
    field :story_id, Ecto.UUID
    field :role, Ecto.Enum, values: @roles
    field :lineage_path, {:array, Ecto.UUID}, default: []
    field :expires_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec
    field :created_at, :utc_datetime_usec
    # LCP-1 §9 signed profile: the agent's OWN public key and the algorithm it
    # signs with. NULL for a bearer dispatch (both-or-neither, DB CHECK). The
    # private half never reaches the server.
    field :agent_pubkey, :binary
    field :alg, :string
  end

  @doc false
  def changeset(dispatch \\ %__MODULE__{}, attrs) do
    dispatch
    |> cast(attrs, [
      :parent_dispatch_id,
      :api_key_id,
      :agent_id,
      :story_id,
      :role,
      :lineage_path,
      :expires_at,
      :revoked_at,
      :created_at,
      :agent_pubkey,
      :alg
    ])
    |> validate_required([:role, :lineage_path, :expires_at])
    |> validate_inclusion(:role, @roles)
    |> validate_signed_profile()
    |> foreign_key_constraint(:parent_dispatch_id)
    |> foreign_key_constraint(:api_key_id)
    |> foreign_key_constraint(:agent_id)
    |> foreign_key_constraint(:story_id)
    |> check_constraint(:alg, name: :dispatches_signed_profile_valid)
  end

  # Ed25519 public keys are exactly 32 bytes (RFC 8032 §5.1.5).
  @ed25519_pubkey_bytes 32

  # Enforce both-or-neither, a known algorithm, and the correct key length at the
  # changeset layer, so a half-enrolled or malformed dispatch is a clean validation
  # error rather than a raw DB constraint error (the DB CHECK
  # dispatches_signed_profile_valid is the backstop). Without the length check a
  # garbage or wrong-length key (e.g. an undecodable hex string kept as raw bytes)
  # would enroll as a "successful" signed dispatch that can never verify a claim,
  # polluting the §9.1.1 enrollment-transparency log with bogus keys.
  defp validate_signed_profile(changeset) do
    pubkey = get_field(changeset, :agent_pubkey)
    alg = get_field(changeset, :alg)

    cond do
      is_nil(pubkey) and is_nil(alg) ->
        changeset

      is_nil(pubkey) or is_nil(alg) ->
        add_error(changeset, :agent_pubkey, "agent_pubkey and alg must be set together")

      alg not in @signed_algorithms ->
        add_error(changeset, :alg, "unsupported signature algorithm")

      alg == "ed25519" and byte_size(pubkey) != @ed25519_pubkey_bytes ->
        add_error(
          changeset,
          :agent_pubkey,
          "ed25519 agent_pubkey must be #{@ed25519_pubkey_bytes} bytes"
        )

      true ->
        changeset
    end
  end
end
