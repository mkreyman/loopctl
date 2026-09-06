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
  - `tags` -- array of alphanumeric tag strings for categorization. The
    `Loopctl.Knowledge.IdempotencyTag.reserved_prefix/0` namespace is reserved
    for per-source idempotency keys and is validated by shape (#583)
  - `source_type` -- advisory origin type: "review_finding", "manual", "agent", "session_log"
  - `source_id` -- optional FK to the originating entity
  - `project_id` -- optional FK to projects (null = tenant-wide)
  - `metadata` -- extensible JSONB

  ## Associations

  - `outgoing_links` -- ArticleLinks where this article is the source
  - `incoming_links` -- ArticleLinks where this article is the target
  """

  use Loopctl.Schema

  alias Loopctl.Embeddings.Dimensions
  alias Loopctl.Knowledge.IdempotencyTag

  @type t :: %__MODULE__{}

  # Canonical taxonomy lives in Loopctl.Knowledge.Categories (single source of
  # truth). `all/0` includes the retired `convention` value so existing rows
  # still load during the reclassification backfill.
  @category_values Loopctl.Knowledge.Categories.all()
  @status_values [:draft, :published, :archived, :superseded]
  @scope_values [:tenant, :system]
  @known_source_types ~w(review_finding manual agent session_log newsletter skill web_article ingestion channel_graduation)
  # `\A`/`\z`, never `^`/`$`: in PCRE `$` also matches immediately BEFORE a
  # trailing newline, so `~r/^[a-zA-Z0-9_-]+$/` accepted "elixir\n" and stored a
  # whitespace-dirty tag as valid. That tag then reads as free text everywhere
  # downstream — `Loopctl.Knowledge.IdempotencyTag.legacy?/1` refuses it, so the
  # #583 promotion can never repair it either (#733 review).
  @tag_pattern ~r/\A[a-zA-Z0-9_-]+\z/
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

    # Written ONLY by `Loopctl.Knowledge.Consolidation` when it unpublishes a confirmed
    # duplicate, and read by `DraftDuplicateSweepWorker` so it can tell consolidation's own
    # retraction from a human draft WITHOUT depending on the retention-bounded audit_log.
    #
    # A COLUMN rather than a `metadata` key for the `stories.lifecycle_entered_at` reason:
    # metadata is cast and whole-map-replaced by PATCH, so one ordinary update would erase
    # the marker. NEVER add this to a `cast` list.
    field :consolidation_retracted_at, :utc_datetime_usec

    # The DURABLE undo record for the nightly `:generic_title` retitle: the title that
    # `Loopctl.Knowledge.Consolidation` replaced, written by `retitle_changeset/2` and by
    # nothing else.
    #
    # A COLUMN rather than a `metadata` key for the same reason as the field above, and it is
    # load-bearing HERE in a way it is not there: what licenses an unattended machine retitle
    # at all is that it can be undone, so an undo record an ordinary caller PATCH erases is
    # not a record. `metadata` is cast and whole-map-replaced, and the audit_log's `old_state`
    # carries the replaced title only until `:audit_retention_days` drops the partition.
    #
    # NEVER add this to a `cast` list.
    field :previous_title, :string

    # The DURABLE record that this draft was staged ON PURPOSE — `draft: true` /
    # `status: "draft"` on create, or ingestion's `publish: false` — rather than being a
    # capture nobody came back for. `Loopctl.Knowledge.DraftConsumer` reads it to give a
    # deliberate stage a longer hold than an abandoned one, and it is a LONGER FLOOR and
    # never a veto: holding is total loss (KB `837daaa0`), so no marker may stop the drain.
    #
    # A COLUMN rather than a `metadata` key for the same reason as the two fields above,
    # and load-bearing here in its own way: a marker an ordinary `PATCH` erases would
    # silently shorten the hold the caller asked for, which is the failure mode of a
    # marker nobody can see fail.
    #
    # Written by `stamp_staged_draft/1` (from `Loopctl.Knowledge.create_article/3` under an
    # explicit `:staged_draft` option) and by `Loopctl.Workers.ContentIngestionWorker`'s
    # `insert_all` rows. NEVER add this to a `cast` list — a caller that could write it
    # could hold its own draft out of the drain for as long as it liked.
    field :staged_draft_at, :utc_datetime_usec

    # REVERSIBLE retrieval tombstone (the memorizz "forgetting is a tombstone" primitive).
    # `suppressed_at` is the whole predicate every read path checks; the other two record
    # WHO and WHY so the act is inspectable and undoable. A suppressed article keeps its
    # status, its embedding, its links and its body — suppression is a claim about
    # RETRIEVABILITY, not about editorial state, which is exactly what `:archived`
    # (terminal) and `unpublish` ("this is a draft") could not say (#605/#606, #608).
    #
    # NEVER add any of the three to a `cast` list. `metadata` is cast and whole-map-REPLACED
    # by `PATCH /api/v1/knowledge/:id`, so a caller that could write these could un-suppress
    # an article with no audit event and no actor. They are written ONLY by
    # `suppression_changeset/2`, reached only from `Loopctl.Knowledge.suppress_article/3`
    # and `unsuppress_article/2` — the same isolation `curated_at`, `previous_title` and
    # `staged_draft_at` above already have, for the same reason.
    field :suppressed_at, :utc_datetime_usec
    field :suppressed_by, :string
    field :suppression_reason, :string

    field :embedding, Pgvector.Ecto.Vector, load_in_query: false
    # Virtual boolean projection of `not is_nil(embedding)` — lets the bulk-embedding
    # path (US-37.4) null-check presence WITHOUT transferring the 1536-dim vector for
    # every article in a ~100-record chunk. Populated by
    # `Knowledge.get_articles_with_embedding_status/2`.
    field :has_embedding, :boolean, virtual: true
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

  # Bounds on the retrieval tombstone's two descriptive fields. Mirrored by the columns'
  # varchar sizes (migration 20260905120000) so the changeset 422 and the DB bound cannot
  # drift; 500 matches `Loopctl.Knowledge.KbCuration`'s `@max_summary`, since the same
  # sentence lands in both places.
  @max_suppression_reason_length 500
  @max_suppressed_by_length 200

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
      message: "has already been taken for this tenant",
      # Without it the violation lands on `:tenant_id` — the first field of the index — which
      # is the same misleading attribution `:articles_tenant_title_active_idx` was already
      # corrected for, and it reaches an operator as `[:tenant_id]` in the consolidation
      # retitle's rejection log. `Loopctl.Projects.Project` sets it for the same reason.
      error_key: :slug
    )
  end

  @doc """
  Changeset for updating an existing article.

  Allows partial updates to title, body, category, status, tags,
  metadata, and project_id. Same constraints as create_changeset.

  ## Curated-marker invalidation (US-31.1, poisoning defense)

  The governed curated marker (`curated_at`/`curated_by`) attests that a curator
  approved a SPECIFIC published-content snapshot as authoritative. Any ordinary,
  agent-reachable edit through this changeset that changes the article's `:title`,
  `:body`, or `:status` therefore **clears the marker** — see
  `clear_curated_marker_on_content_change/1`. This closes the edit-after-curate
  poisoning class: an agent cannot overwrite a curated article's body (or flip a
  curated draft to `:published`) and keep the authoritative marker; re-curation
  must go back through the governed `Loopctl.Knowledge.mark_curated/3` path against
  the final published content. Pure metadata/tags/category/project edits preserve
  the marker (they do not change what the curator approved).

  This is defense in depth alongside the fact that the marker is NOT castable here:
  `mark_curated/3`'s `curation_changeset/3` is the only writer, and this changeset
  is the only in-place clearer.
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
    |> clear_curated_marker_on_content_change()
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
      message: "has already been taken for this tenant",
      # Without it the violation lands on `:tenant_id` — the first field of the index — which
      # is the same misleading attribution `:articles_tenant_title_active_idx` was already
      # corrected for, and it reaches an operator as `[:tenant_id]` in the consolidation
      # retitle's rejection log. `Loopctl.Projects.Project` sets it for the same reason.
      error_key: :slug
    )
  end

  @doc """
  Changeset for the nightly consolidation pass's `:generic_title` retitle.

  `update_changeset/2` plus the two things that make an UNATTENDED, machine-authored title
  change safe and coherent, neither of which an ordinary caller edit wants:

  1. **It stamps `:previous_title`** — the durable undo record. What licenses
     `Loopctl.Knowledge.Consolidation` to retitle a placeholder without a human is that the
     write is reversible, so the record of what to restore must outlive an ordinary caller
     `PATCH`. It is a COLUMN and is not castable anywhere; this function is its only writer.
     The `consolidation_title_generated` MARKER stays on `metadata` deliberately — that one
     is advisory (it answers "is this title ours to replace"), and losing it fails SAFE, by
     declining a future retitle rather than by performing an unrecorded one.

  2. **It regenerates `:slug`** — `maybe_generate_slug/1` fires only when the slug is absent,
     so `update_changeset/2` leaves a retitled article on the slug derived from its old
     title FOREVER. On this path the old title is a placeholder by construction, so the old
     slug is `untitled-a1b2c3` and no reader is served by keeping it. It is scoped to THIS
     changeset rather than added to `update_changeset/2` for the obvious reason: a slug is a
     URL, and silently rotating it on every human title edit would break every standing link
     in the wiki to buy nothing.

  Both fire only when `:title` actually changes, so a metadata-only write through this
  function neither stamps an undo record nor rotates a URL.

  A regenerated slug carries a random suffix and so effectively never collides — but
  `update_changeset/2`'s `unique_constraint`s on both slug indexes are inherited, so if one
  ever does, the write comes back `{:error, changeset}` tagged `[:slug]` and the caller
  skips exactly as it does for a taken title. It is never an exception.
  """
  @spec retitle_changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def retitle_changeset(article, attrs) do
    article
    |> update_changeset(attrs)
    |> stamp_previous_title(article)
    |> regenerate_slug()
  end

  @doc """
  Stamps `staged_draft_at` on a create changeset whose caller explicitly asked to stage.

  A no-op unless the article is actually landing as a `:draft`: the option says what the
  CALLER asked for, and a `force: true` or ungated create that ends up published was not a
  stage. `:staged_draft_at` is not in any `cast` list, so this `put_change/3` — never
  caller input — is the only way it moves on this path.
  """
  @spec stamp_staged_draft(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  def stamp_staged_draft(changeset) do
    if get_field(changeset, :status) == :draft do
      put_change(changeset, :staged_draft_at, DateTime.utc_now())
    else
      changeset
    end
  end

  defp stamp_previous_title(changeset, article) do
    case get_change(changeset, :title) do
      nil -> changeset
      _changed -> put_change(changeset, :previous_title, article.title)
    end
  end

  defp regenerate_slug(changeset) do
    case get_change(changeset, :title) do
      title when is_binary(title) and title != "" -> maybe_put_generated_slug(changeset, title)
      _ -> changeset
    end
  end

  @doc false
  def known_source_types, do: @known_source_types

  @doc "Maximum number of tags allowed per article (single source of truth)."
  def max_tags, do: @max_tags

  @doc """
  The shape a single tag must have to survive this changeset.

  Public because a tag can reach the database WITHOUT passing through here —
  `Loopctl.Workers.TagBackfillWorker` persists with `update_all` — so any writer that
  bypasses the changeset must validate against the SAME pattern or it stores rows this
  module would have rejected. Those surface later as a 422 on an unrelated caller's PATCH,
  which is a defect report pointing at the wrong code.

  A caller may be STRICTER (the re-tagger requires lowercase, because it normalises first).
  It may not be looser.
  """
  @spec tag_pattern() :: Regex.t()
  def tag_pattern, do: @tag_pattern

  @doc """
  The tag-shape contract as published to API callers.

  Interpolated into the OpenAPI `tags` description on create and update, next to
  `Loopctl.Knowledge.IdempotencyTag.contract_description/0`, so the spec and the enforcement
  cannot state different rules. The character class and the length are read from the same
  attributes the changeset validates against, not restated.
  """
  @spec tag_contract_description() :: String.t()
  def tag_contract_description do
    "Each tag must match #{Regex.source(@tag_pattern)} — letters, digits, underscore and " <>
      "hyphen only, anchored end to end, so surrounding whitespace (including a trailing " <>
      "newline) is rejected 422 rather than stored. Maximum #{@max_tag_length} characters " <>
      "per tag and #{@max_tags} tags per article."
  end

  @doc "Maximum length of a single tag (single source of truth, same reason as `tag_pattern/0`)."
  @spec max_tag_length() :: pos_integer()
  def max_tag_length, do: @max_tag_length

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
  - `embedding` -- a list of floats (must match `expected_dimension`) or `nil` to clear
  - `expected_dimension` -- US-41.1 AC-41.1.11: the dimension is RESOLVED ONCE per
    operation/batch by `Loopctl.Embeddings.active_dimension/1` and PASSED IN, so
    this validator stays PURE — no Repo read, no process dictionary. Defaults to
    the deployment `:embedding_dimensions` so every pre-41.1 call site keeps its
    exact previous behaviour.

  ## Returns

  An `Ecto.Changeset` with dimension validation applied when `embedding` is not nil.
  """
  @spec embedding_changeset(
          %__MODULE__{},
          list(number()) | nil,
          String.t() | nil,
          pos_integer()
        ) :: Ecto.Changeset.t()
  def embedding_changeset(
        article,
        embedding,
        content_hash \\ nil,
        expected_dimension \\ Application.get_env(:loopctl, :embedding_dimensions, 1536)
      ) do
    article
    |> change(%{embedding: embedding, embedding_content_hash: content_hash})
    |> Dimensions.validate_vector_length(:embedding, expected_dimension)
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

  @doc """
  Changeset for the REVERSIBLE retrieval tombstone — the only writer of `suppressed_at`,
  `suppressed_by` and `suppression_reason`.

  None of the three is castable anywhere, here included: they are `change/2`d from values
  the CONTEXT derives (the clock, the server-resolved actor label, the caller's reason
  after validation), never from request params. Reached only through
  `Loopctl.Knowledge.suppress_article/3` and `Loopctl.Knowledge.unsuppress_article/2`.

  Pass `nil` to LIFT the suppression, which clears all three together. Keeping a stale
  `suppressed_by`/`suppression_reason` on a live article would read as a tombstone to
  anyone inspecting the row while every retrieval surface returned it — the two halves must
  never disagree.

  Lengths are validated here AND bounded at the column (varchar 200 / 500): the changeset
  gives a caller a 422 naming the field, the column is what holds if a future writer forgets.

  ## Returns

  An `Ecto.Changeset` carrying only the tombstone fields.
  """
  @spec suppression_changeset(%__MODULE__{}, map() | nil) :: Ecto.Changeset.t()
  def suppression_changeset(article, nil) do
    change(article, %{suppressed_at: nil, suppressed_by: nil, suppression_reason: nil})
  end

  def suppression_changeset(article, %{} = attrs) do
    article
    |> change(%{
      suppressed_at: Map.fetch!(attrs, :suppressed_at),
      suppressed_by: Map.get(attrs, :suppressed_by),
      suppression_reason: Map.get(attrs, :suppression_reason)
    })
    |> validate_length(:suppressed_by, max: @max_suppressed_by_length)
    |> validate_length(:suppression_reason, max: @max_suppression_reason_length)
  end

  @doc "Max bytes of a `suppression_reason`, mirrored by the column's varchar bound."
  @spec max_suppression_reason_length() :: pos_integer()
  def max_suppression_reason_length, do: @max_suppression_reason_length

  @doc "Max bytes of a `suppressed_by` actor label, mirrored by the column's varchar bound."
  @spec max_suppressed_by_length() :: pos_integer()
  def max_suppressed_by_length, do: @max_suppressed_by_length

  # US-31.1 poisoning defense: any in-place edit that changes the article's
  # title, body, or status invalidates a previously-set governed curated marker,
  # forcing re-curation through mark_curated/3 against the final content. Only acts
  # when the article currently carries a marker AND a content/lifecycle field is
  # actually changing (a no-op edit or a pure metadata/tags edit keeps the marker).
  # `:curated_at`/`:curated_by` are NOT in this changeset's cast list, so these
  # put_change calls — not caller input — are the only way they change here.
  defp clear_curated_marker_on_content_change(changeset) do
    content_or_status_changed? =
      Enum.any?([:title, :body, :status], &Map.has_key?(changeset.changes, &1))

    already_curated? = not is_nil(get_field(changeset, :curated_at))

    if content_or_status_changed? and already_curated? do
      changeset
      |> put_change(:curated_at, nil)
      |> put_change(:curated_by, nil)
    else
      changeset
    end
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

        # The reserved idempotency namespace (#583). Enforced HERE, in the one
        # validation both create_changeset/2 and update_changeset/2 run, because
        # the namespace guarantee every idempotency read depends on must be
        # enforced by every writer, not by one call site.
        IdempotencyTag.reserved?(tag) and not IdempotencyTag.well_formed?(tag) ->
          add_error(cs, :tags, IdempotencyTag.reserved_violation_message(), tag: tag)

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
