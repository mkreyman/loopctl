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

  Every row is scoped by `tenant_id` (RLS-enforced on the OLTP path) plus a
  required `subject_id` — the API-key identity that owns the memory. `subject_id`
  is resolved SERVER-SIDE from the caller's key (see `Loopctl.Memory.subject_id_for/1`)
  and is NEVER accepted from request params. `tenant_id` and `subject_id` are set
  programmatically on the struct, never via `cast/3`. NOTE (US-28.2): the recall
  path runs on `Loopctl.HeavyReadRepo` (BYPASSRLS), so recall isolation is an
  explicit `(tenant_id, subject_id)` predicate, NOT RLS.

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
  - `superseded_by` — self-reference to the memory that replaced this one (nullable)
  """

  use Loopctl.Schema

  @type t :: %__MODULE__{}

  @sources [:explicit, :promoted]

  # Memory text is byte-capped to bound memory/wire footprint and to keep it
  # within embedding-provider input limits. A single memory is far smaller than
  # a curated article (100KB body); 100_000 bytes is a generous ceiling.
  @max_text_bytes 100_000

  # A blank subject_id must never be a usable owner (see SessionMemory / #163).
  @max_subject_id_length 200

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
    :project_id,
    :superseded_by
  ]

  @doc """
  Changeset for creating a memory.

  `tenant_id` and `subject_id` are set programmatically on the struct and must
  NOT appear in `attrs`. `embedding` is never cast here — it is populated
  asynchronously via `embedding_changeset/3` in US-28.2. Validates required
  fields, `confidence` range, and caps `text` byte size.
  """
  @spec create_changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def create_changeset(memory \\ %__MODULE__{}, attrs) do
    memory
    |> cast(attrs, @cast_fields)
    |> validate_required([:subject_id, :tenant_id, :text])
    |> validate_subject_id()
    |> validate_text_byte_size()
    |> validate_number(:confidence,
      greater_than_or_equal_to: 0.0,
      less_than_or_equal_to: 1.0
    )
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:tenant_id)
    |> foreign_key_constraint(:superseded_by)
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
