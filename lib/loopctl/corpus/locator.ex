defmodule Loopctl.Corpus.Locator do
  @moduledoc """
  Custom `Ecto.Type` for `document_chunks.locator`: ANY jsonb value the client
  chooses — an object (`%{"page" => 3}`), an ARRAY (a heading path), or a scalar
  (a bare page number).

  ## Why not `field :locator, :map`

  `:map` narrows the column to a JSON OBJECT in both directions:
  `Ecto.Type.cast(:map, ["Chapter 1"])` is `:error`, so a client whose chunker
  emits array locators could not index at all (`Loopctl.Corpus.build_chunk_rows/3`
  halts the whole batch on the first invalid changeset), and
  `Ecto.Type.load(:map, ["Chapter 1"])` is `:error` too, so a row that got in by
  any other path would make the whole chunk row unloadable rather than merely
  unwritable. The column is plain `jsonb NOT NULL DEFAULT '{}'`, which admits all
  three shapes, and AC-43.1.2 gives the shape to the client ("loopctl only stores
  and returns it").

  `type/0` is `:map` because that is how a value reaches the SCALAR `jsonb`
  column — a `{:array, :map}` field would map to a Postgres `jsonb[]` column
  instead. `Loopctl.Coordination.RefsList` stores a list in a scalar `jsonb`
  column the same way.

  ## Nothing is normalised

  The value is stored and returned VERBATIM: the locator participates in the
  `(corpus_id, source_ref, locator)` idempotency key, so a normalisation that
  reordered keys would silently duplicate every chunk on the next index run.
  `cast/1` therefore checks ONE thing and changes nothing — that the term can be
  encoded as JSON. A term the jsonb encoder cannot render (a tuple, a struct with
  no `Jason.Encoder`) would otherwise raise out of the insert instead of failing
  as a changeset error.
  """

  use Ecto.Type

  @impl true
  def type, do: :map

  @impl true
  def cast(nil), do: {:ok, nil}

  def cast(value) do
    case Jason.encode(value) do
      {:ok, _json} -> {:ok, value}
      {:error, _reason} -> :error
    end
  end

  @impl true
  def load(value), do: {:ok, value}

  @impl true
  def dump(value), do: {:ok, value}
end
