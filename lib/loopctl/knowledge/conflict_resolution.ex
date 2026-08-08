defmodule Loopctl.Knowledge.ConflictResolution do
  @moduledoc """
  A retrieving agent's VERDICT on a `:potential_conflict` article pair (route-the-findings
  #4, step 1). The agent judges — with the live context the nightly job lacks — and records
  it here; a nightly executor applies `:supersede` (create a `supersedes` link + retire the
  loser), while `:dismiss` takes effect immediately (the pair drops out of the conflict
  queue). `:merge` is recorded but executed later (the LLM-synthesis step, #4 step 2).

  The KB/executor never re-judges: it acts only on what a grounded agent recorded. One row
  per canonical (sorted) article pair — re-annotation upserts (last-write-wins), so the
  freshest grounded judgment governs.

  ## `confidence` is a GRANT, not an assertion

  The nightly executor retires an article on `disposition: :supersede, confidence: :high`
  with nobody in the loop, so on a `:supersede` `confidence` is the field that authorizes
  an unattended retirement. It is therefore resolved server-side in
  `Loopctl.Knowledge.annotate_conflict/3` from the recorder's role — never taken verbatim
  from request params — and the role that produced it is persisted in `annotated_by_role`
  so the executor can re-check the authorization rather than infer it.
  `requested_confidence` keeps what the caller asked for when the grant came out lower, so
  a capped verdict stays auditable, and its pair stays in the conflict queue until an
  authorized key re-records it. A `:merge` retires nothing (it synthesizes a new draft and
  leaves both sources published), so it is never capped and executes at agent role.

  A `:high`-confidence `:supersede` additionally requires `evidence`: the one verdict that
  retires an article unattended must carry the reason it was reached. That validation lives
  HERE, at the single point every writer converges on, rather than in the controller — the
  same reason the reserved-tag rule sits on the Article changeset.

  `tenant_id` is set programmatically, never cast.
  """

  use Loopctl.Schema

  @type t :: %__MODULE__{}

  @classification_values [:redundant, :complementary, :contradictory]
  @disposition_values [:dismiss, :supersede, :merge]
  @confidence_values [:high, :medium, :low]

  schema "conflict_resolutions" do
    tenant_field()

    belongs_to :source_article, Loopctl.Knowledge.Article
    belongs_to :target_article, Loopctl.Knowledge.Article
    belongs_to :authoritative_article, Loopctl.Knowledge.Article

    field :classification, Ecto.Enum, values: @classification_values
    field :disposition, Ecto.Enum, values: @disposition_values
    field :confidence, Ecto.Enum, values: @confidence_values, default: :medium
    # What the caller asked for, kept only when the server granted something lower.
    field :requested_confidence, Ecto.Enum, values: @confidence_values
    field :evidence, :string
    field :annotated_by, :string
    # The role of the key that recorded this verdict, derived server-side. Backfilled from
    # `annotated_by` for pre-migration rows; still `nil` where that could not be parsed —
    # an unknown recorder is not an authorized one
    # (`Loopctl.Knowledge.execute_conflict_resolutions/2`).
    field :annotated_by_role, :string
    field :annotated_at, :utc_datetime_usec
    field :executed_at, :utc_datetime_usec
    field :execution_result, :map, default: %{}

    timestamps(type: :utc_datetime_usec)
  end

  @cast_fields [
    :source_article_id,
    :target_article_id,
    :authoritative_article_id,
    :classification,
    :disposition,
    :confidence,
    :requested_confidence,
    :evidence,
    :annotated_by,
    :annotated_by_role,
    :annotated_at,
    :executed_at,
    :execution_result
  ]

  @doc """
  Changeset for an agent-recorded resolution. `tenant_id` is set on the struct, not cast.
  Requires a canonical (sorted) pair and a disposition; `:supersede`/`:merge` require the
  `authoritative_article_id` to be one of the two pair members, and a `:high`-confidence
  `:supersede` requires `evidence`.
  """
  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(resolution \\ %__MODULE__{}, attrs) do
    resolution
    |> cast(attrs, @cast_fields)
    |> validate_required([:source_article_id, :target_article_id, :disposition, :annotated_at])
    |> validate_inclusion(:disposition, @disposition_values)
    |> validate_pair_order()
    |> validate_authoritative_in_pair()
    |> validate_evidence_for_unattended_supersede()
    |> foreign_key_constraint(:source_article_id)
    |> foreign_key_constraint(:target_article_id)
    |> unique_constraint([:tenant_id, :source_article_id, :target_article_id],
      name: :conflict_resolutions_tenant_pair_index
    )
  end

  # The pair is unordered; store it canonically (source < target by UUID string) so the
  # unique index collapses (A,B) and (B,A) to one row.
  defp validate_pair_order(changeset) do
    src = get_field(changeset, :source_article_id)
    tgt = get_field(changeset, :target_article_id)

    cond do
      is_nil(src) or is_nil(tgt) -> changeset
      src == tgt -> add_error(changeset, :target_article_id, "must differ from source")
      src <= tgt -> changeset
      true -> add_error(changeset, :source_article_id, "pair must be sorted (source <= target)")
    end
  end

  defp validate_authoritative_in_pair(changeset) do
    disposition = get_field(changeset, :disposition)
    auth = get_field(changeset, :authoritative_article_id)
    src = get_field(changeset, :source_article_id)
    tgt = get_field(changeset, :target_article_id)

    cond do
      disposition in [:supersede, :merge] and is_nil(auth) ->
        add_error(changeset, :authoritative_article_id, "is required for #{disposition}")

      not is_nil(auth) and auth not in [src, tgt] ->
        add_error(changeset, :authoritative_article_id, "must be one of the pair")

      true ->
        changeset
    end
  end

  # The ONE verdict shape that retires a published article with nobody watching:
  # `:supersede` at the confidence the nightly executor acts on. It must name the reason it
  # was reached, so the retirement is reviewable after the fact from the row alone. Checked
  # on the GRANTED confidence — a request capped down to `:medium` never reaches the
  # executor, so it is not held to this bar.
  #
  # Whitespace is not evidence: `validate_required/2` already rejects `""` and a
  # whitespace-only string trims to `""` under the default `:trim` behaviour.
  defp validate_evidence_for_unattended_supersede(changeset) do
    if get_field(changeset, :disposition) == :supersede and
         get_field(changeset, :confidence) == :high do
      validate_required(changeset, [:evidence],
        message: "is required for a high-confidence supersede (it retires an article unattended)"
      )
    else
      changeset
    end
  end

  @doc "Allowed disposition values."
  def dispositions, do: @disposition_values
end
