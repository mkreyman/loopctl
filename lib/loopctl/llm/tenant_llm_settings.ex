defmodule Loopctl.Llm.TenantLlmSettings do
  @moduledoc """
  Schema for the `tenant_llm_settings` table — a tenant's BYO Anthropic + embedding
  configuration (Epic 28 residual, #179; embeddings closes the operator-funded
  embedding-spend gap).

  Each tenant has at most ONE row (unique `tenant_id`). It holds two SEPARATE,
  encrypted secrets:

    * `api_key`           — the tenant's own **Anthropic** key (knowledge LLM work).
    * `embedding_api_key` — the tenant's own **OpenAI-compatible embedding** key
      (article vector embeddings + semantic search).

  Both are encrypted at rest via Cloak (`Loopctl.Vault.Binary`, AES-256-GCM) and
  `redact: true` so neither ever appears in `inspect/1` or log output. The
  per-operation model fields (`extraction_model` / `classification_model` /
  `merge_model` for Anthropic; `embedding_model` for embeddings) let a tenant pick
  a different model per operation; each is a free-form, plausible model id (NOT
  restricted to an allow-list) or NULL to fall back to the server default.

  ## Security invariants

  - `api_key` / `embedding_api_key` are NEVER placed in a `cast/3` list — they are
    set programmatically via `put_change/3` so a stray param can't overwrite them
    and they never land in the changeset's `params` echoed by error rendering.
  - Both are `redact: true` — `inspect(%TenantLlmSettings{})` shows `**redacted**`.
  - No serializer ever returns a key (only `has_*_key` + a last-4 hint).
  """

  use Loopctl.Schema

  @type t :: %__MODULE__{}

  # A plausible Anthropic model id — non-empty, bounded, no whitespace. We do NOT
  # restrict to a known-model allow-list: the tenant may use any model their key
  # permits (Sonnet, Opus, Haiku, dated snapshots, future ids).
  @model_format ~r/^[A-Za-z0-9._:-]+$/
  @max_model_length 200
  @max_api_key_length 500

  schema "tenant_llm_settings" do
    tenant_field()

    field :api_key, Loopctl.Vault.Binary, redact: true
    field :extraction_model, :string
    field :classification_model, :string
    field :merge_model, :string

    # BYO embeddings: the tenant's OWN OpenAI-compatible key + model, SEPARATE from
    # the Anthropic key above.
    field :embedding_api_key, Loopctl.Vault.Binary, redact: true
    field :embedding_model, :string

    timestamps()
  end

  @model_fields [:extraction_model, :classification_model, :merge_model, :embedding_model]

  @doc """
  Changeset for the per-operation model fields ONLY.

  `api_key` is deliberately excluded from the cast — set it via `put_api_key/2`.
  """
  @spec models_changeset(t(), map()) :: Ecto.Changeset.t()
  def models_changeset(settings, attrs) do
    settings
    # Cast ONLY the model fields — never let the raw api_key transit through
    # `cast/3` into `changeset.params` (review #15), where it could surface in a
    # logged/rendered changeset. The key is set separately via put_api_key/2.
    |> cast(model_attrs(attrs), @model_fields)
    |> validate_models()
    # A concurrent first-insert race yields a clean {:error, changeset} (422)
    # instead of an Ecto.ConstraintError (500) on the unique tenant_id index.
    |> unique_constraint(:tenant_id)
  end

  @doc """
  Sets the encrypted Anthropic `api_key` on a changeset via `put_change/3` (never
  `cast`), validating it's a non-empty, bounded string. A `nil`/absent value leaves
  the existing key untouched; a blank string is rejected.
  """
  @spec put_api_key(Ecto.Changeset.t(), String.t() | nil) :: Ecto.Changeset.t()
  def put_api_key(changeset, value), do: put_secret_key(changeset, :api_key, value)

  @doc """
  Sets the encrypted `embedding_api_key` (the tenant's OpenAI embedding key) on a
  changeset via `put_change/3` (never `cast`) — same non-empty/bounded validation
  and never-cast handling as `put_api_key/2`.
  """
  @spec put_embedding_api_key(Ecto.Changeset.t(), String.t() | nil) :: Ecto.Changeset.t()
  def put_embedding_api_key(changeset, value),
    do: put_secret_key(changeset, :embedding_api_key, value)

  # Shared validator for the two encrypted secret fields: never cast, set via
  # put_change/3, reject blank/oversized, leave untouched on nil.
  defp put_secret_key(changeset, _field, nil), do: changeset

  defp put_secret_key(changeset, field, value) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" ->
        add_error(changeset, field, "must not be blank")

      String.length(trimmed) > @max_api_key_length ->
        add_error(changeset, field, "is too long (max #{@max_api_key_length} characters)")

      true ->
        put_change(changeset, field, trimmed)
    end
  end

  defp put_secret_key(changeset, field, _other),
    do: add_error(changeset, field, "must be a string")

  # Keep ONLY the model fields (string- or atom-keyed) so the api_key can never
  # reach `cast/3`/`changeset.params` (review #15).
  @model_string_keys Enum.map(@model_fields, &Atom.to_string/1)
  defp model_attrs(attrs) when is_map(attrs) do
    Map.take(attrs, @model_fields ++ @model_string_keys)
  end

  defp model_attrs(_), do: %{}

  defp validate_models(changeset) do
    Enum.reduce(@model_fields, changeset, fn field, acc ->
      acc
      |> validate_format(field, @model_format,
        message: "must be a plausible model id (letters, digits, . _ : -)"
      )
      |> validate_length(field, min: 1, max: @max_model_length)
    end)
  end
end
