defmodule Loopctl.Memory.Memory do
  @moduledoc """
  Schema for the `memories` table — the long-term, semantically-recalled memory
  of an agent subject (Epic 28, Agent Memory Part 1).

  Unlike `Loopctl.Memory.SessionMemory` (short-term, chronological, expiring),
  a `Memory` row is a durable fact/observation embedded as a `vector(1536)` and
  recalled by cosine similarity over an HNSW index. Embeddings are populated
  ASYNCHRONOUSLY (US-28.2) — `embedding` is NULL on insert here.

  This table is kept STRICTLY SEPARATE from the Knowledge Wiki `articles` table:
  memories are agent-private working memory, not curated tenant knowledge, and
  have a different lifecycle (promotion, supersede, forget).

  ## Scope / security boundary

  Every row is scoped by `tenant_id` plus a required `subject_id` — the API-key
  identity that owns the memory. `subject_id` is resolved SERVER-SIDE from the
  caller's key (see `Loopctl.Memory.subject_id_for/1`) and is NEVER accepted from
  request params. `tenant_id` and `subject_id` are set programmatically on the
  struct, never via `cast/3`.

  NOTE (US-28.2): the `Loopctl.Memory` context reaches this table ONLY through
  BYPASSRLS repos — `Loopctl.AdminRepo` for OLTP and `Loopctl.HeavyReadRepo` for
  recall — so the table's RLS policies do NOT engage on any of its access paths.
  Isolation is the explicit `(tenant_id, subject_id)` predicate on every query (the
  recall pool additionally backstopped by `Loopctl.HeavyRead`'s structural guard),
  NOT RLS. The RLS policies apply only to a hypothetical RLS-enforcing
  `Loopctl.Repo` caller, of which this context has none.

  ## Fields

  - `subject_id` — scope owner = the API-key identity (required)
  - `project_id` — optional FK to projects (null = tenant-wide)
  - `text` — the memory content (required, byte-capped)
  - `embedding` — `vector(1536)`, `load_in_query: false`; NULL until US-28.2 populates it
  - `embedding_content_hash` — SHA-256 hex of the text that produced `embedding`
  - `confidence` — float in [0, 1], default 1.0
  - `source` — `:explicit` (default) or `:promoted` (written by the Part 2 compiler)
  - `source_session_id` — the session this memory was promoted from (nullable)
  - `tags` — array of strings, default `[]`
  - `metadata` — extensible JSONB, default `%{}` (mirrors `SessionMemory.metadata`;
    added so the generic `metadata` contract advertised by the memory HTTP API and
    the `memory_remember` MCP tool actually persists for this, the DEFAULT tier —
    see the review finding recorded on US-28.4)
  - `superseded_by` — self-reference to the memory that replaced this one (nullable)
  """

  use Loopctl.Schema

  @type t :: %__MODULE__{}

  @sources [:explicit, :promoted]

  # Memory text is byte-capped to bound memory/wire footprint (a single memory is
  # far smaller than a curated article's 100KB body; 100_000 bytes is a generous
  # ceiling that still rejects pathological payloads).
  #
  # NOTE (US-28.2): this cap is NOT an embedding-provider input limit. 100KB is
  # ~25k tokens, well beyond typical embedding-model context windows (e.g.
  # text-embedding-3 caps ~8191 tokens). The async embedding worker MUST
  # chunk/truncate `text` to the provider's token limit before embedding —
  # a max-size memory that passes this changeset will NOT fit an embedder as-is.
  @max_text_bytes 100_000

  # A blank subject_id must never be a usable owner (see SessionMemory / #163).
  @max_subject_id_length 200

  # The embedder's input is the memory text SLICED to this many chars (the embedding
  # model's ~8191-token window is far below the 100KB text cap). `embedding_input/1`
  # and `embedding_content_hash/1` are the SINGLE source of truth for that slice + its
  # SHA-256 content hash, shared by BOTH the async `MemoryEmbeddingWorker` (which
  # embeds + hashes async) and the synchronous US-29.2 promotion write path (which
  # sets `embedding_content_hash` AT WRITE TIME for the exact-dedupe partial unique
  # index). Keeping one implementation guarantees the two hashes match, so the async
  # worker's `already_embedded?` idempotency check is not defeated by a drifted slice.
  @embedding_max_chars 32_000

  schema "memories" do
    tenant_field()
    belongs_to :project, Loopctl.Projects.Project

    field :subject_id, :string
    field :text, :string
    field :embedding, Pgvector.Ecto.Vector, load_in_query: false
    field :embedding_content_hash, :string
    field :confidence, :float, default: 1.0
    field :source, Ecto.Enum, values: @sources, default: :explicit
    field :source_session_id, :string
    field :tags, {:array, :string}, default: []
    field :metadata, :map, default: %{}

    belongs_to :superseded_by_memory, __MODULE__,
      foreign_key: :superseded_by,
      references: :id,
      type: :binary_id,
      define_field: true

    timestamps(type: :utc_datetime_usec)
  end

  @cast_fields [
    :text,
    :embedding_content_hash,
    :confidence,
    :source,
    :source_session_id,
    :tags,
    :metadata
  ]

  @doc """
  Changeset for creating a memory.

  `tenant_id`, `subject_id`, and `project_id` are set programmatically on the
  struct and must NOT appear in `attrs`. Both `project_id` and `superseded_by`
  are FKs whose Postgres constraint is checked with RLS BYPASSED, so accepting
  either from request params would let a caller point at ANOTHER tenant's row (a
  cross-tenant graph edge + INSERT-time existence oracle). `superseded_by` is
  set by `forget/2` (US-28.2); `project_id` is set by the US-28.2 write path from
  the caller's already-authorized context — never cast — mirroring the sibling
  `Loopctl.WorkBreakdown.Story` schema, which likewise sets `project_id`
  programmatically rather than casting it. (The Knowledge Wiki `Article` casts
  `project_id`, but a `Memory` is a stricter per-subject security boundary and
  matches `Story`, not `Article`, here.) `embedding` is never cast here — it is
  populated asynchronously via `embedding_changeset/3` in US-28.2. `metadata` is
  cast (mirrors `SessionMemory`) so the generic `metadata` contract advertised by
  the memory HTTP API / `memory_remember` MCP tool persists for this tier too.
  Validates required fields, `confidence` presence + range, and caps `text` byte
  size.
  """
  @spec create_changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def create_changeset(memory \\ %__MODULE__{}, attrs) do
    memory
    |> cast(attrs, @cast_fields)
    |> normalize_nil(:tags, [])
    |> normalize_nil(:metadata, %{})
    |> validate_required([:subject_id, :tenant_id, :text, :confidence])
    |> validate_subject_id()
    |> validate_text_byte_size()
    |> validate_number(:confidence,
      greater_than_or_equal_to: 0.0,
      less_than_or_equal_to: 1.0
    )
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:tenant_id)
  end

  @doc """
  Changeset for setting or clearing a memory's embedding vector.

  The only changeset that may modify `:embedding`. Validates dimensions against
  the configured `:embedding_dimensions` (default 1536) when non-nil. Used by
  US-28.2's async embedding worker.
  """
  @spec embedding_changeset(%__MODULE__{}, list(number()) | nil, String.t() | nil) ::
          Ecto.Changeset.t()
  def embedding_changeset(memory, embedding, content_hash \\ nil) do
    memory
    |> change(%{embedding: embedding, embedding_content_hash: content_hash})
    |> validate_embedding_dimensions()
  end

  @doc "Allowed `source` values."
  @spec sources() :: [atom()]
  def sources, do: @sources

  @doc "Maximum `text` byte size."
  @spec max_text_bytes() :: pos_integer()
  def max_text_bytes, do: @max_text_bytes

  @doc """
  The exact text handed to the embedder: `text` sliced to the model's char window.

  The single source of truth for the slice shared by the async embedding worker and
  the synchronous US-29.2 promotion write path.
  """
  @spec embedding_input(String.t()) :: String.t()
  def embedding_input(text) when is_binary(text), do: String.slice(text, 0, @embedding_max_chars)

  @doc """
  SHA-256 hex of `embedding_input(text)` — the `embedding_content_hash` value.

  Computed synchronously at promotion write time (for the exact-dedupe partial unique
  index) AND by the async `MemoryEmbeddingWorker` after embedding; both call this so
  the hashes match and the worker's idempotency check holds.
  """
  @spec embedding_content_hash(String.t()) :: String.t()
  def embedding_content_hash(text) when is_binary(text) do
    text
    |> embedding_input()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  # A caller may pass an explicit `tags: nil`; `cast/3` records that as a nil
  # CHANGE (the schema default `[]` differs from nil), but the DB column is
  # `NOT NULL`. Without this, insert would raise a raw Postgrex
  # `not_null_violation` instead of honoring the changeset contract. Normalize a
  # nil back to the column default so the DB default governs.
  defp normalize_nil(changeset, field, default) do
    case get_field(changeset, field) do
      nil -> put_change(changeset, field, default)
      _ -> changeset
    end
  end

  defp validate_subject_id(changeset) do
    case get_field(changeset, :subject_id) do
      nil ->
        changeset

      subject_id when is_binary(subject_id) ->
        cond do
          String.trim(subject_id) == "" ->
            add_error(changeset, :subject_id, "must not be blank")

          byte_size(subject_id) > @max_subject_id_length ->
            add_error(changeset, :subject_id, "too long (max %{max} bytes)",
              max: @max_subject_id_length
            )

          true ->
            changeset
        end

      _ ->
        add_error(changeset, :subject_id, "must be a string")
    end
  end

  defp validate_text_byte_size(changeset) do
    case get_change(changeset, :text) do
      text when is_binary(text) ->
        if byte_size(text) > @max_text_bytes do
          add_error(changeset, :text, "exceeds maximum size of %{max} bytes (got %{actual})",
            max: @max_text_bytes,
            actual: byte_size(text)
          )
        else
          changeset
        end

      _ ->
        changeset
    end
  end

  defp validate_embedding_dimensions(changeset) do
    case get_change(changeset, :embedding) do
      nil ->
        changeset

      %Pgvector{} = vector ->
        check_dimensions(changeset, length(Pgvector.to_list(vector)))

      embedding when is_list(embedding) ->
        check_dimensions(changeset, length(embedding))

      _ ->
        changeset
    end
  end

  defp check_dimensions(changeset, actual) do
    expected = Application.get_env(:loopctl, :embedding_dimensions, 1536)

    if actual == expected do
      changeset
    else
      add_error(changeset, :embedding, "dimension mismatch: expected %{expected}, got %{actual}",
        expected: expected,
        actual: actual
      )
    end
  end
end
