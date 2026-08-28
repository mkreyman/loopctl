defmodule Loopctl.Corpus.DocumentChunk do
  @moduledoc """
  US-43.1 — a VERBATIM chunk of a document that lives in the client's own repo.

  loopctl stores the pointer (`source_ref` + `locator`), the content hash, and —
  in `:server_embedded` mode — the text itself. It never chunks, fetches or parses
  a document: the client does that and sends the result.

  ## `locator` belongs to the CLIENT

  It is jsonb and its internal shape is the client's: a PDF page, a byte range, a
  heading path, an EDI loop and segment — an object, an ARRAY or a scalar, which is
  why the field is `Loopctl.Corpus.Locator` and not `:map` (that type admits only
  objects, in both directions). loopctl stores and returns it VERBATIM and
  must never validate or normalise it — a normalisation that reordered keys would
  change the idempotency key and silently duplicate every chunk on the next index
  run. jsonb's own key-order normalisation is the one that is safe, because
  Postgres does it consistently.

  `(corpus_id, source_ref, locator)` is unique; that is what makes re-indexing
  idempotent. `content_hash` is deliberately NOT part of the key — it is compared
  against the incoming chunk to decide unchanged-vs-replaced. In the key, a chunk
  whose text moved would insert a SECOND row at the same locator instead of
  replacing the first.

  ## `text` may be NULL

  That is the `:client_embedded` state: the client embedded locally and the server
  holds a vector it cannot read. `snippet` is the optional, client-chosen exposure;
  the corpus's `allow_snippets` governs it and is enforced in US-43.3.
  """

  use Loopctl.Schema

  import Ecto.Changeset

  alias Loopctl.Corpus.Corpus
  alias Loopctl.Corpus.Locator

  @type t :: %__MODULE__{}

  # The snippet ceiling, declared HERE — on the schema that stores the column — because
  # BOTH ends read it: `changeset/2` refuses a longer one on the WRITE, and
  # `Loopctl.Corpus.Search` reads it for the `left(...)` truncation on the READ and for
  # the OpenAPI `maxLength` the controller publishes. Declared on the reader alone, the
  # request schema advertised a cap nothing enforced and a 50 KB snippet was accepted and
  # stored verbatim (the `@max_inline_content_bytes` drift class).
  @max_snippet_chars 320

  @doc "The maximum length a stored `snippet` may have."
  @spec max_snippet_chars() :: pos_integer()
  def max_snippet_chars, do: @max_snippet_chars

  schema "document_chunks" do
    tenant_field()

    field :source_ref, :string
    field :locator, Locator, default: %{}
    field :text, :string
    field :snippet, :string
    field :content_hash, :string
    field :ordinal, :integer

    belongs_to :corpus, Corpus

    timestamps()
  end

  @doc """
  Changeset for a chunk. `tenant_id` is NEVER cast — `Loopctl.Corpus.upsert_chunks/3`
  sets it on the struct.

  `snippet` is bounded by `max_snippet_chars/0` — the SAME attribute the search path
  truncates to and the OpenAPI request schema publishes — so the documented bound and
  the enforced bound are one number.

  `locator` is cast as-is and is NOT validated or normalised (see the moduledoc); it
  defaults to `%{}` rather than NULL because a NULL locator is DISTINCT from every
  other NULL in a btree unique index and would silently defeat the idempotency the
  index exists to provide. The one locator refused is one loopctl cannot store
  verbatim — see `validate_storable_locator/1`.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(chunk, attrs) do
    chunk
    |> cast(attrs, [:corpus_id, :source_ref, :locator, :text, :snippet, :content_hash, :ordinal])
    |> validate_required([:corpus_id, :source_ref, :content_hash])
    |> validate_length(:snippet, max: @max_snippet_chars)
    |> put_default_locator()
    |> validate_storable_locator()
    |> foreign_key_constraint(:tenant_id)
    |> foreign_key_constraint(:corpus_id)
    |> unique_constraint([:corpus_id, :source_ref, :locator],
      name: :document_chunks_corpus_source_locator_index,
      message: "has already been taken for this locator in this corpus",
      # `:corpus_id` is the first field of the index, but `upsert_chunks/3` OVERRIDES it with the
      # tenant-resolved corpus's id, so it is not a field the caller can act on. Attribute the
      # collision to the identity the caller does supply. Same reason as `Loopctl.Corpus.Corpus`.
      error_key: :source_ref
    )
  end

  defp put_default_locator(changeset) do
    case get_field(changeset, :locator) do
      nil -> put_change(changeset, :locator, %{})
      _ -> changeset
    end
  end

  # jsonb keeps the LAST of two duplicate object keys (`'{"a":1,"a":2}'::jsonb` is
  # `{"a": 2}`), so `%{:page => 1, "page" => 2}` would be STORED as something other
  # than what the client sent — breaking the verbatim contract this schema is built
  # on — and `Loopctl.Corpus`'s in-batch duplicate-key guard, which compares Elixir
  # terms, would not see the collision Postgres does. Refusing it is not the shape
  # validation the moduledoc forbids: the shape stays the client's; what is refused
  # is a value with no faithful stored form, and guessing which half Postgres keeps
  # would be the normalisation.
  defp validate_storable_locator(changeset) do
    if colliding_keys?(get_field(changeset, :locator)) do
      add_error(
        changeset,
        :locator,
        "has an object whose keys collide once rendered as jsonb strings — jsonb " <>
          "would keep only one of them, so the locator cannot be stored verbatim"
      )
    else
      changeset
    end
  end

  defp colliding_keys?(value) when is_map(value) and not is_struct(value) do
    keys = Map.keys(value)

    length(Enum.uniq(Enum.map(keys, &to_string/1))) != length(keys) or
      Enum.any?(Map.values(value), &colliding_keys?/1)
  end

  defp colliding_keys?(value) when is_list(value), do: Enum.any?(value, &colliding_keys?/1)
  defp colliding_keys?(_value), do: false
end
