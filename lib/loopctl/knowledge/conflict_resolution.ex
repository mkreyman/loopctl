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
    field :evidence, :string
    field :annotated_by, :string
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
    :evidence,
    :annotated_by,
    :annotated_at,
    :executed_at,
    :execution_result
  ]

  @doc """
  Changeset for an agent-recorded resolution. `tenant_id` is set on the struct, not cast.
  Requires a canonical (sorted) pair and a disposition; `:supersede`/`:merge` require the
  `authoritative_article_id` to be one of the two pair members.
  """
  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(resolution \\ %__MODULE__{}, attrs) do
    resolution
    |> cast(attrs, @cast_fields)
    |> validate_required([:source_article_id, :target_article_id, :disposition, :annotated_at])
    |> validate_inclusion(:disposition, @disposition_values)
    |> validate_pair_order()
    |> validate_authoritative_in_pair()
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

  @doc "Allowed disposition values."
  def dispositions, do: @disposition_values
end
