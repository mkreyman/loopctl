defmodule Loopctl.Memory.SessionPromotion do
  @moduledoc """
  Schema for the `session_promotions` table — the promotion WATERMARK (Epic 29,
  Agent Memory Part 2 / auto-promotion, US-29.2).

  One row per `(tenant_id, subject_id, session_id)` recording the
  `session_content_hash` a session was last compiled at (plus the
  `last_turn_inserted_at` of the newest turn seen and the `promoted_at` timestamp of
  the run). Both promotion triggers — the explicit per-session job and the
  cross-tenant cron sweep — skip a session whose CURRENT content hash equals the
  stored watermark's, so an unchanged session is never re-compiled. It is upserted on
  EVERY compile run, including zero-survivor runs (that is what stops the
  re-LLM-every-tick loop).

  ## Scope / security boundary

  Like the rest of `Loopctl.Memory`, isolation is the explicit
  `(tenant_id, subject_id)` predicate — `tenant_id`/`subject_id` are set
  programmatically on the struct, never cast from params, and the context reaches
  this table only through the BYPASSRLS `Loopctl.AdminRepo`.
  """

  use Loopctl.Schema

  @type t :: %__MODULE__{}

  schema "session_promotions" do
    tenant_field()

    field :subject_id, :string
    field :session_id, :string
    field :session_content_hash, :string
    field :last_turn_inserted_at, :utc_datetime_usec
    # The monotonic `seq` of the newest turn seen at the last compile — the sweep's
    # tiebreaker when a turn is appended at the exact microsecond of
    # `last_turn_inserted_at` (US-29.2 review hardening). Nullable: legacy rows written
    # before this column keep NULL and are handled by the sweep's NULL-safe comparison.
    field :last_turn_seq, :integer
    field :promoted_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @cast_fields [
    :session_id,
    :session_content_hash,
    :last_turn_inserted_at,
    :last_turn_seq,
    :promoted_at
  ]

  @doc """
  Changeset for inserting/upserting a promotion watermark.

  `tenant_id` and `subject_id` are set programmatically on the struct and must NOT
  appear in `attrs`.
  """
  @spec upsert_changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def upsert_changeset(watermark \\ %__MODULE__{}, attrs) do
    watermark
    |> cast(attrs, @cast_fields)
    |> validate_required([
      :tenant_id,
      :subject_id,
      :session_id,
      :session_content_hash,
      :promoted_at
    ])
    |> foreign_key_constraint(:tenant_id)
    |> unique_constraint([:tenant_id, :subject_id, :session_id],
      name: :session_promotions_scope_session_uniq_idx
    )
  end
end
