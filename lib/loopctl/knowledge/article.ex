defmodule Loopctl.Knowledge.Article do
  @moduledoc """
  Schema for the `articles` table.

  Articles are the core knowledge units in the Knowledge Wiki. Each article
  represents a reusable pattern, convention, decision, finding, or reference
  within a tenant's knowledge base.

  ## Fields

  - `title` -- article title, unique per tenant among non-archived/superseded
  - `body` -- full article content (text, max 100KB)
  - `category` -- knowledge type: pattern, convention, decision, finding, reference
  - `status` -- lifecycle state: draft, published, archived, superseded
  - `tags` -- array of alphanumeric tag strings for categorization
  - `source_type` -- advisory origin type: "review_finding", "manual", "agent", "session_log"
  - `source_id` -- optional FK to the originating entity
  - `project_id` -- optional FK to projects (null = tenant-wide)
  - `metadata` -- extensible JSONB

  ## Associations

  - `outgoing_links` -- ArticleLinks where this article is the source
  - `incoming_links` -- ArticleLinks where this article is the target
  """

  use Loopctl.Schema

  @type t :: %__MODULE__{}

  @category_values [:pattern, :convention, :decision, :finding, :reference]
  @status_values [:draft, :published, :archived, :superseded]
  @known_source_types ~w(review_finding manual agent session_log)
  @tag_pattern ~r/^[a-zA-Z0-9_-]+$/
  @max_tags 20
  @max_tag_length 100

  schema "articles" do
    tenant_field()
    belongs_to :project, Loopctl.Projects.Project

    field :title, :string
    field :body, :string
    field :category, Ecto.Enum, values: @category_values
    field :status, Ecto.Enum, values: @status_values, default: :draft
    field :tags, {:array, :string}, default: []
    field :source_type, :string
    field :source_id, :binary_id
    field :metadata, :map, default: %{}

    field :embedding, Pgvector.Ecto.Vector

    has_many :outgoing_links, Loopctl.Knowledge.ArticleLink, foreign_key: :source_article_id
    has_many :incoming_links, Loopctl.Knowledge.ArticleLink, foreign_key: :target_article_id

    timestamps()
  end

  @cast_fields [
    :title,
    :body,
    :category,
    :status,
    :tags,
    :source_type,
    :source_id,
    :metadata,
    :project_id
  ]

  @doc """
  Changeset for creating a new article.

  `tenant_id` is set programmatically and must not appear in attrs.
  Defaults `status` to `:draft` if not provided.
  """
  @spec create_changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def create_changeset(article \\ %__MODULE__{}, attrs) do
    article
    |> cast(attrs, @cast_fields)
    |> validate_required([:title, :body, :category])
    |> validate_length(:title, max: 500)
    |> validate_length(:body, max: 100_000)
    |> validate_tags()
    |> validate_source_type()
    |> validate_metadata()
    |> foreign_key_constraint(:project_id)
    |> unique_constraint([:tenant_id, :title],
      name: :articles_tenant_title_active_idx,
      message: "has already been taken for this tenant"
    )
  end

  @doc """
  Changeset for updating an existing article.

  Allows partial updates to title, body, category, status, tags,
  metadata, and project_id. Same constraints as create_changeset.
  """
  @spec update_changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def update_changeset(article, attrs) do
    article
    |> cast(attrs, [:title, :body, :category, :status, :tags, :metadata, :project_id])
    |> validate_length(:title, max: 500)
    |> validate_length(:body, max: 100_000)
    |> validate_tags()
    |> validate_metadata()
    |> foreign_key_constraint(:project_id)
    |> unique_constraint([:tenant_id, :title],
      name: :articles_tenant_title_active_idx,
      message: "has already been taken for this tenant"
    )
  end

  @doc false
  def known_source_types, do: @known_source_types

  @valid_transitions [
    {:draft, :published},
    {:published, :draft},
    {:published, :archived},
    {:draft, :archived},
    {:superseded, :draft}
  ]

  @doc """
  Returns whether a status transition is valid.

  ## Valid transitions

  - draft -> published
  - published -> draft
  - published -> archived
  - draft -> archived
  - superseded -> draft

  ## Examples

      iex> Article.valid_transition?(:draft, :published)
      true

      iex> Article.valid_transition?(:archived, :published)
      false
  """
  @spec valid_transition?(atom(), atom()) :: boolean()
  def valid_transition?(from, to), do: {from, to} in @valid_transitions

  @doc """
  Changeset for setting or clearing an article's embedding vector.

  This is the only changeset that may modify the `:embedding` field.
  The standard `create_changeset/2` and `update_changeset/2` do not
  include `:embedding` in their cast fields, ensuring embeddings are
  only set via dedicated functions.

  ## Parameters

  - `article` -- an existing `%Article{}` struct
  - `embedding` -- a list of floats (must match configured dimensions) or `nil` to clear

  ## Returns

  An `Ecto.Changeset` with dimension validation applied when `embedding` is not nil.
  """
  @spec embedding_changeset(%__MODULE__{}, list(number()) | nil) :: Ecto.Changeset.t()
  def embedding_changeset(article, embedding) do
    article
    |> change(%{embedding: embedding})
    |> validate_embedding_dimensions()
  end

  # --- Private validations ---

  defp validate_tags(changeset) do
    case get_change(changeset, :tags) do
      nil ->
        changeset

      tags when is_list(tags) ->
        changeset
        |> validate_tag_count(tags)
        |> validate_tag_format(tags)

      _other ->
        changeset
    end
  end

  defp validate_tag_count(changeset, tags) do
    if length(tags) > @max_tags do
      add_error(changeset, :tags, "must not exceed #{@max_tags} tags")
    else
      changeset
    end
  end

  defp validate_tag_format(changeset, tags) do
    Enum.reduce(tags, changeset, fn tag, cs ->
      cond do
        not is_binary(tag) ->
          add_error(cs, :tags, "each tag must be a string")

        String.length(tag) > @max_tag_length ->
          add_error(cs, :tags, "tag %{tag} exceeds maximum length of #{@max_tag_length}",
            tag: tag
          )

        not Regex.match?(@tag_pattern, tag) ->
          add_error(cs, :tags, "tag %{tag} contains invalid characters", tag: tag)

        true ->
          cs
      end
    end)
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

  defp validate_source_type(changeset) do
    case get_change(changeset, :source_type) do
      nil ->
        changeset

      source_type when source_type in @known_source_types ->
        changeset

      unknown ->
        add_error(changeset, :source_type, "unknown source type: %{type}",
          type: unknown,
          validation: :source_type_advisory
        )
    end
  end

  defp validate_embedding_dimensions(changeset) do
    case get_change(changeset, :embedding) do
      nil ->
        changeset

      %Pgvector{} = vector ->
        expected = Application.get_env(:loopctl, :embedding_dimensions, 1536)
        actual = length(Pgvector.to_list(vector))

        if actual == expected do
          changeset
        else
          add_error(
            changeset,
            :embedding,
            "dimension mismatch: expected %{expected}, got %{actual}",
            expected: expected,
            actual: actual
          )
        end

      embedding when is_list(embedding) ->
        expected = Application.get_env(:loopctl, :embedding_dimensions, 1536)
        actual = length(embedding)

        if actual == expected do
          changeset
        else
          add_error(
            changeset,
            :embedding,
            "dimension mismatch: expected %{expected}, got %{actual}",
            expected: expected,
            actual: actual
          )
        end

      _ ->
        changeset
    end
  end
end
