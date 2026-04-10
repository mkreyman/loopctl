defmodule Loopctl.Knowledge.ArticleLink do
  @moduledoc """
  Schema for the `article_links` table.

  ArticleLinks represent directed, typed relationships between two articles
  within the same tenant. Links are **immutable** -- once created they cannot
  be updated, only deleted and re-created. This is enforced by omitting
  `updated_at` from timestamps.

  ## Fields

  - `id`                -- binary UUID primary key
  - `tenant_id`         -- FK to tenants (set programmatically, never cast)
  - `source_article_id` -- FK to articles (the origin of the link)
  - `target_article_id` -- FK to articles (the destination of the link)
  - `relationship_type` -- enum: relates_to, derived_from, contradicts, supersedes
  - `metadata`          -- extensible JSONB, defaults to `%{}`
  - `inserted_at`       -- creation timestamp (no updated_at)

  ## Constraints

  - Self-links are rejected (source == target).
  - A composite unique index on `(tenant_id, source_article_id,
    target_article_id, relationship_type)` prevents duplicate links.
  - FK constraints use `on_delete: :restrict` to prevent orphaned links.
  """

  use Loopctl.Schema

  @type t :: %__MODULE__{}

  @relationship_type_values [:relates_to, :derived_from, :contradicts, :supersedes]

  schema "article_links" do
    tenant_field()

    belongs_to :source_article, Loopctl.Knowledge.Article
    belongs_to :target_article, Loopctl.Knowledge.Article

    field :relationship_type, Ecto.Enum, values: @relationship_type_values
    field :metadata, :map, default: %{}

    timestamps(updated_at: false)
  end

  @cast_fields [:source_article_id, :target_article_id, :relationship_type, :metadata]

  @doc """
  Changeset for creating a new article link.

  `tenant_id` is set programmatically and must not appear in attrs.
  Validates that source and target articles differ (no self-links).
  """
  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(article_link \\ %__MODULE__{}, attrs) do
    article_link
    |> cast(attrs, @cast_fields)
    |> validate_required([:source_article_id, :target_article_id, :relationship_type])
    |> validate_no_self_link()
    |> validate_metadata()
    |> foreign_key_constraint(:source_article_id)
    |> foreign_key_constraint(:target_article_id)
    |> unique_constraint(
      [:tenant_id, :source_article_id, :target_article_id, :relationship_type],
      name: :article_links_tenant_src_tgt_rel_index,
      message: "link already exists between these articles with this relationship type"
    )
  end

  defp validate_metadata(changeset) do
    validate_change(changeset, :metadata, fn :metadata, value ->
      if is_map(value) and not is_struct(value) do
        []
      else
        [metadata: "must be a map"]
      end
    end)
  end

  defp validate_no_self_link(changeset) do
    validate_change(changeset, :target_article_id, fn :target_article_id, target_id ->
      source_id = get_field(changeset, :source_article_id)

      if source_id != nil and target_id == source_id do
        [target_article_id: "cannot link an article to itself"]
      else
        []
      end
    end)
  end
end
