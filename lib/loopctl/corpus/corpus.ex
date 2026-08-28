defmodule Loopctl.Corpus.Corpus do
  @moduledoc """
  US-43.1 — a reference-document CORPUS: the index loopctl hosts for files that
  stay in the client's own repo.

  ## The corpus pins its own dimension

  `dim` and `embedding_model` are properties of THIS corpus, pinned at creation and
  immutable thereafter (`AC-43.1.13`). They are never resolved from the tenant: a
  tenant whose ARTICLE corpus is pinned at 1536 must be able to index a document
  corpus with a local 768-dimension model at the same time, and the per-tenant
  resolvers in `Loopctl.Embeddings` would either return the wrong number or — worse
  — WRITE the tenant pin as a side effect of a corpus write. The corpus's `dim` is
  read from this row and from nowhere else.

  Re-dimensioning is delete-and-re-index by design. There is no distilled state to
  preserve: the source files are the truth.

  ## `mode`

    * `:server_embedded` — the client sends chunk text and loopctl embeds it. Both
      retrieval lanes work.
    * `:client_embedded` — the client embeds locally and sends vectors; the chunk's
      `text` is NULL and the server cannot read the content.

  ## `allow_snippets`

  Derived from `mode` when the caller does not state it: TRUE for
  `:server_embedded` (loopctl holds the text already), FALSE for
  `:client_embedded` (US-43.3's privacy-preserving default — a snippet IS text the
  server sees). The column carries NO DDL default precisely so this
  mode-conditional decision lives in one place that a caller cannot bypass by
  omission. It is stored here in this story and ENFORCED in US-43.3.
  """

  use Loopctl.Schema

  import Ecto.Changeset

  alias Loopctl.Embeddings
  alias Loopctl.Projects.Project

  @type t :: %__MODULE__{}

  @modes [:server_embedded, :client_embedded]

  # Set once, at creation. Rejected — not silently dropped — on update, so a caller
  # that believes it re-dimensioned a corpus learns otherwise (AC-43.1.13).
  @immutable [:dim, :embedding_model, :mode]

  schema "corpora" do
    tenant_field()

    field :slug, :string
    field :name, :string
    field :description, :string
    field :mode, Ecto.Enum, values: @modes
    field :embedding_model, :string
    field :dim, :integer
    field :allow_snippets, :boolean

    belongs_to :project, Project

    timestamps()
  end

  @doc "The valid corpus modes."
  @spec modes() :: [atom()]
  def modes, do: @modes

  @doc "The fields pinned at creation and refused on update."
  @spec immutable_fields() :: [atom()]
  def immutable_fields, do: @immutable

  @doc """
  Creation changeset. `tenant_id` is NEVER cast — `Loopctl.Corpus.create_corpus/2`
  sets it on the struct.

  `dim` must be a member of `Loopctl.Embeddings.supported_dimensions/0`
  (AC-43.1.4): a dimension outside that published set has no pre-built HNSW index,
  and index DDL is migration-plane only.
  """
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(%__MODULE__{} = corpus, attrs) do
    corpus
    |> cast(attrs, [
      :project_id,
      :slug,
      :name,
      :description,
      :mode,
      :embedding_model,
      :dim,
      :allow_snippets
    ])
    |> validate_required([:slug, :name, :mode, :embedding_model, :dim])
    |> validate_length(:slug, min: 1, max: 100)
    |> validate_format(:slug, ~r/\A[a-z0-9][a-z0-9\-_]*\z/,
      message: "must be lowercase alphanumeric with hyphens or underscores"
    )
    |> validate_supported_dimension()
    |> put_allow_snippets_from_mode()
    |> validate_required([:allow_snippets])
    |> foreign_key_constraint(:tenant_id)
    |> foreign_key_constraint(:project_id)
    |> unique_constraint([:tenant_id, :slug],
      name: :corpora_tenant_id_slug_index,
      message: "has already been taken for this tenant",
      # Without it the violation lands on `:tenant_id` — the first field of the index, and one
      # the client never sends and cannot control — so a slug collision would reach the caller
      # of US-43.2's `POST /corpora` as a 422 naming a field it has no way to change.
      # `Loopctl.Knowledge.Article` and `Loopctl.Projects.Project` set it for the same reason.
      error_key: :slug
    )
    |> check_constraint(:dim, name: :corpora_dim_positive, message: "must be greater than 0")
    |> check_constraint(:mode, name: :corpora_mode_valid, message: "is invalid")
  end

  @doc """
  Update changeset for the MUTABLE fields only.

  `dim`, `embedding_model` and `mode` are not cast, and an attempt to change any of
  them is an ERROR on that field rather than a silent drop (AC-43.1.13 / TC-43.1.3).
  A silent drop would let a caller believe it had re-dimensioned a corpus whose
  vectors are all still at the old dimension.

  `project_id` is not cast either, and that is a TENANT-BOUNDARY decision rather
  than an immutability one: `foreign_key_constraint(:project_id)` is an existence
  check evaluated against every tenant's projects on the BYPASSRLS `AdminRepo`, so
  the ownership check has to live in the context, where `tenant_id` is (see
  `Loopctl.Corpus.create_corpus/2`). Leaving the field castable here with only the
  FK behind it would pre-open a cross-tenant edge for whatever adds the first
  update path. A future re-scope adds the cast AND that check together.
  """
  @spec update_changeset(t(), map()) :: Ecto.Changeset.t()
  def update_changeset(%__MODULE__{} = corpus, attrs) do
    corpus
    |> cast(attrs, [:name, :description, :allow_snippets])
    |> validate_required([:name, :allow_snippets])
    |> reject_immutable_changes(attrs)
  end

  defp validate_supported_dimension(changeset) do
    supported = Embeddings.supported_dimensions()

    validate_change(changeset, :dim, fn :dim, dim ->
      if dim in supported do
        []
      else
        [
          dim:
            "must be one of the dimensions this instance publishes " <>
              "(#{inspect(supported)}) — a dimension outside that set has no pre-built " <>
              "HNSW index, and index DDL is migration-plane only, so supporting a new " <>
              "one requires a migration (the same reason .well-known/loopctl publishes " <>
              "the set)"
        ]
      end
    end)
  end

  # The mode-conditional default the DDL cannot express. An explicit value from the
  # caller wins; omission resolves from `mode`.
  defp put_allow_snippets_from_mode(changeset) do
    case {get_change(changeset, :allow_snippets), get_field(changeset, :allow_snippets)} do
      {nil, nil} -> put_change(changeset, :allow_snippets, default_allow_snippets(changeset))
      _ -> changeset
    end
  end

  defp default_allow_snippets(changeset) do
    get_field(changeset, :mode) == :server_embedded
  end

  defp reject_immutable_changes(changeset, attrs) do
    Enum.reduce(@immutable, changeset, fn field, acc ->
      reject_if_changed(acc, field, fetch_attr(attrs, field))
    end)
  end

  defp reject_if_changed(changeset, _field, :error), do: changeset

  defp reject_if_changed(changeset, field, {:ok, value}) do
    if same_value?(Map.fetch!(changeset.data, field), value) do
      changeset
    else
      add_error(
        changeset,
        field,
        "is pinned at creation and cannot be changed — re-dimensioning a corpus is " <>
          "delete-and-re-index by design"
      )
    end
  end

  defp fetch_attr(attrs, field) when is_map(attrs) do
    case Map.fetch(attrs, field) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(attrs, Atom.to_string(field))
    end
  end

  defp fetch_attr(_attrs, _field), do: :error

  # Compared as strings so `:server_embedded`/`"server_embedded"` and `768`/`"768"`
  # are the same value: a no-op restatement of a pinned field is not a change.
  defp same_value?(current, given), do: stringify(current) == stringify(given)

  defp stringify(nil), do: nil
  defp stringify(value) when is_binary(value), do: value
  defp stringify(value), do: to_string(value)
end
