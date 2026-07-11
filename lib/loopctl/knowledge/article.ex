defmodule Loopctl.Knowledge.Article do
  @moduledoc """
  Schema for the `articles` table.

  Articles are the core knowledge units in the Knowledge Wiki. Each article is
  classified by `category` (pattern, decision, finding, reference, playbook,
  insight, entity, idea, quote, question — plus the retired `convention`). The
  canonical taxonomy lives in `Loopctl.Knowledge.Categories`.

  ## Fields

  - `title` -- article title, unique per tenant among non-archived/superseded
  - `body` -- full article content (text, max 100KB)
  - `category` -- knowledge type; see `Loopctl.Knowledge.Categories`
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

  # Canonical taxonomy lives in Loopctl.Knowledge.Categories (single source of
  # truth). `all/0` includes the retired `convention` value so existing rows
  # still load during the reclassification backfill.
  @category_values Loopctl.Knowledge.Categories.all()
  @status_values [:draft, :published, :archived, :superseded]
  @scope_values [:tenant, :system]
  @known_source_types ~w(review_finding manual agent session_log newsletter skill web_article ingestion)
  @tag_pattern ~r/^[a-zA-Z0-9_-]+$/
  @slug_format ~r/^[a-z0-9][a-z0-9-]*[a-z0-9]$/
  # Topical tags only. Structural identity (e.g. a "hub", or an article's source)
  # is carried by source_type/source_id and idempotency_key (#137), so we raise
  # the cap (#138) rather than add a separate kind/type field.
  @max_tags 50
  @max_tag_length 100

  schema "articles" do
    tenant_field()
    belongs_to :project, Loopctl.Projects.Project

    field :title, :string
    field :body, :string
    field :category, Ecto.Enum, values: @category_values
    field :status, Ecto.Enum, values: @status_values, default: :draft
    field :scope, Ecto.Enum, values: @scope_values, default: :tenant
    field :slug, :string
    field :tags, {:array, :string}, default: []
    field :source_type, :string
    field :source_id, :binary_id
    field :idempotency_key, :string
    field :metadata, :map, default: %{}

    field :embedding, Pgvector.Ecto.Vector, load_in_query: false
    # SHA-256 hex of the exact text that produced `embedding` — the idempotency key
    # that lets ArticleEmbeddingWorker skip re-calling the paid provider on retry.
    field :embedding_content_hash, :string

    # GOVERNED curated (authoritative) marker (US-31.1). Deliberately EXCLUDED from
    # `@cast_fields` and `update_changeset/2` — writable ONLY via `curation_changeset/3`
    # (invoked from `Loopctl.Knowledge.mark_curated/3`), mirroring the `embedding`
    # isolation precedent. This is what stops an agent from self-promoting its own
    # article to "authoritative" (agents CAN set `category`/`metadata`, so those are
    # never sufficient — see `Loopctl.Knowledge.curated?/1`).
    field :curated_at, :utc_datetime_usec
    field :curated_by, :string

    has_many :outgoing_links, Loopctl.Knowledge.ArticleLink, foreign_key: :source_article_id
    has_many :incoming_links, Loopctl.Knowledge.ArticleLink, foreign_key: :target_article_id

    timestamps()
  end

  @cast_fields [
    :title,
    :body,
    :category,
    :status,
    :scope,
    :slug,
    :tags,
    :source_type,
    :source_id,
    :idempotency_key,
    :metadata,
    :project_id
  ]

  @max_idempotency_key_length 255

  # Agent-memory conventions in `metadata` (validated only when `agent_id` is
  # present — a curated reference article without an agent_id is unaffected).
  # `memory_type` is the agent-episodic kind (distinct from `category`, the
  # knowledge kind); `visibility` scopes sharing.
  # `visibility` values:
  #   - `shared` — visible to all roles in the tenant
  #   - `private` — visible only to the agent who owns it (when agent_id is set)
  #   - `owner` — equivalent to `private` (synonym, marking owner-only intent explicitly)
  @valid_memory_types ~w(observation finding summary decision question task)
  @valid_visibilities ~w(shared private owner)
  @max_agent_id_length 200

  @doc "Allowed agent-memory `memory_type` values."
  @spec valid_memory_types() :: [String.t()]
  def valid_memory_types, do: @valid_memory_types

  @doc """
  Allowed agent-memory `visibility` values.

  - `shared` — visible to all roles
  - `private` — visible only to the owning agent (read-only, scoped by agent_id)
  - `owner` — equivalent to `private` (synonym marking owner-only intent)
  """
  @spec valid_visibilities() :: [String.t()]
  def valid_visibilities, do: @valid_visibilities

  @doc """
  Changeset for creating a new article.

  `tenant_id` is set programmatically and must not appear in attrs.
  Defaults `status` to `:draft` if not provided.

  NOTE: `:status` is castable here and is **trusted from `attrs`** — this
  changeset does NOT enforce who may create a `:published` (or
  `:archived`/`:superseded`) article. Setting the create-time status is the
  caller's responsibility: `LoopctlWeb.ArticleController.create/2` sets it
  server-side (published by default, or draft when the caller opts in) and never
  trusts a caller-supplied `:status` beyond the draft opt-in, and
  `Loopctl.Knowledge.OKF` forces `:draft`. A future caller of `create_article/3`
  MUST likewise sanitize `:status` (or gate the role) rather than pass an
  unvalidated caller value. (Publishing is no longer gated on the create path;
  publishing an EXISTING draft via the workflow endpoints remains role-gated.)
  """
  @spec create_changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def create_changeset(article \\ %__MODULE__{}, attrs) do
    article
    |> cast(attrs, @cast_fields)
    |> validate_required([:title, :body, :category])
    |> validate_length(:title, max: 500)
    |> validate_body_byte_size()
    |> validate_length(:idempotency_key, max: @max_idempotency_key_length)
    |> validate_slug()
    |> validate_tags()
    |> validate_source_type()
    |> validate_metadata()
    |> validate_agent_metadata()
    |> maybe_generate_slug()
    |> foreign_key_constraint(:project_id)
    |> unique_constraint(:title,
      name: :articles_tenant_title_active_idx,
      message: "is already taken in this tenant"
    )
    |> unique_constraint(:idempotency_key,
      name: :articles_tenant_idempotency_key_idx,
      message: "has already been captured (idempotency_key)"
    )
    |> unique_constraint(:slug,
      name: :articles_system_slug_idx,
      message: "has already been taken"
    )
    |> unique_constraint([:tenant_id, :slug],
      name: :articles_tenant_slug_idx,
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
    |> cast(attrs, [:title, :body, :category, :status, :tags, :slug, :metadata, :project_id])
    |> validate_length(:title, max: 500)
    |> validate_body_byte_size()
    |> validate_slug()
    |> validate_tags()
    |> validate_metadata()
    |> validate_agent_metadata()
    |> foreign_key_constraint(:project_id)
    |> unique_constraint(:title,
      name: :articles_tenant_title_active_idx,
      message: "is already taken in this tenant"
    )
    |> unique_constraint(:slug,
      name: :articles_system_slug_idx,
      message: "has already been taken"
    )
    |> unique_constraint([:tenant_id, :slug],
      name: :articles_tenant_slug_idx,
      message: "has already been taken for this tenant"
    )
  end

  @doc false
  def known_source_types, do: @known_source_types

  @doc "Maximum number of tags allowed per article (single source of truth)."
  def max_tags, do: @max_tags

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
  @spec embedding_changeset(%__MODULE__{}, list(number()) | nil, String.t() | nil) ::
          Ecto.Changeset.t()
  def embedding_changeset(article, embedding, content_hash \\ nil) do
    article
    |> change(%{embedding: embedding, embedding_content_hash: content_hash})
    |> validate_embedding_dimensions()
  end

  @doc """
  Changeset for setting or clearing the GOVERNED curated marker (US-31.1).

  This is the ONLY changeset that may modify `:curated_at`/`:curated_by`. Neither
  `create_changeset/2` nor `update_changeset/2` includes them in their cast fields,
  so an agent writing an ordinary create/update — even one that freely sets
  `category`/`metadata` — cannot make its own article "curated" (authoritative).
  The marker is written exclusively through the admin/curation-gated
  `Loopctl.Knowledge.mark_curated/3` context path.

  ## Parameters

  - `article` -- an existing `%Article{}` struct
  - `curated_at` -- a `DateTime` (mark) or `nil` (unmark)
  - `curated_by` -- optional advisory actor label (e.g. `"user:admin"`); ignored
    (forced `nil`) when unmarking

  ## Returns

  An `Ecto.Changeset` carrying only the marker changes.
  """
  @spec curation_changeset(%__MODULE__{}, DateTime.t() | nil, String.t() | nil) ::
          Ecto.Changeset.t()
  def curation_changeset(article, curated_at, curated_by \\ nil)

  def curation_changeset(article, nil, _curated_by) do
    change(article, %{curated_at: nil, curated_by: nil})
  end

  def curation_changeset(article, %DateTime{} = curated_at, curated_by) do
    change(article, %{curated_at: curated_at, curated_by: curated_by})
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

  # When `metadata.agent_id` is present, the article is an agent memory: validate
  # the `agent_id`, `memory_type`, and `visibility` conventions. Without an
  # `agent_id`, no agent-memory validation applies (curated references are free-form).
  defp validate_agent_metadata(changeset) do
    case get_change(changeset, :metadata) do
      metadata when is_map(metadata) and not is_struct(metadata) ->
        if Map.has_key?(metadata, "agent_id") or Map.has_key?(metadata, :agent_id) do
          changeset
          |> validate_metadata_agent_id(metadata)
          |> validate_metadata_member(metadata, "memory_type", :memory_type, @valid_memory_types)
          |> validate_metadata_member(metadata, "visibility", :visibility, @valid_visibilities)
        else
          changeset
        end

      _ ->
        changeset
    end
  end

  defp validate_metadata_agent_id(changeset, metadata) do
    agent_id = metadata["agent_id"] || metadata[:agent_id]

    cond do
      not is_binary(agent_id) ->
        add_error(changeset, :metadata, "agent_id must be a string")

      # A blank agent_id is rejected (#163): an identity-less agent key scopes reads
      # to agent_id = "", so a stored "" owner would be readable by ANY such key —
      # the empty string must never be a usable owner identity.
      String.trim(agent_id) == "" ->
        add_error(changeset, :metadata, "agent_id must not be blank")

      byte_size(agent_id) > @max_agent_id_length ->
        add_error(
          changeset,
          :metadata,
          "agent_id too long (max #{@max_agent_id_length} characters)"
        )

      true ->
        changeset
    end
  end

  defp validate_metadata_member(changeset, metadata, str_key, atom_key, allowed) do
    value = metadata[str_key] || metadata[atom_key]

    cond do
      is_nil(value) ->
        changeset

      not is_binary(value) ->
        add_error(changeset, :metadata, "#{str_key} must be a string")

      value in allowed ->
        changeset

      true ->
        add_error(
          changeset,
          :metadata,
          "invalid #{str_key} '#{String.slice(value, 0, 50)}'; must be one of: #{Enum.join(allowed, ", ")}"
        )
    end
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

  # Body size enforced as byte_size to ensure a hard ceiling on memory/wire footprint.
  # Worst-case UTF-8 encoding of 100k graphemes ≈ 400KB; we allow up to 500KB.
  @max_body_bytes 500_000

  defp validate_body_byte_size(changeset) do
    case get_change(changeset, :body) do
      nil ->
        changeset

      body when is_binary(body) ->
        if byte_size(body) > @max_body_bytes do
          add_error(changeset, :body, "exceeds maximum size of %{max} bytes (got %{actual})",
            max: @max_body_bytes,
            actual: byte_size(body)
          )
        else
          changeset
        end

      _ ->
        changeset
    end
  end

  defp validate_slug(changeset) do
    case get_change(changeset, :slug) do
      nil ->
        changeset

      slug when is_binary(slug) ->
        changeset
        |> validate_format(:slug, @slug_format,
          message: "must be lowercase alphanumeric with hyphens"
        )
        |> validate_length(:slug, min: 2, max: 64)

      _ ->
        changeset
    end
  end

  defp maybe_generate_slug(changeset) do
    case {get_field(changeset, :slug), get_field(changeset, :title)} do
      {nil, title} when is_binary(title) and title != "" ->
        maybe_put_generated_slug(changeset, title)

      _ ->
        changeset
    end
  end

  defp maybe_put_generated_slug(changeset, title) do
    base =
      title
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9\s-]/, "")
      |> String.replace(~r/\s+/, "-")
      |> String.trim("-")
      |> String.slice(0, 56)

    suffix = :crypto.strong_rand_bytes(3) |> Base.encode16(case: :lower)
    slug = if base != "", do: "#{base}-#{suffix}", else: suffix

    if Regex.match?(@slug_format, slug) do
      put_change(changeset, :slug, slug)
    else
      changeset
    end
  end
end
