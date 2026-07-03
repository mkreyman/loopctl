defmodule Loopctl.Llm.TenantLlmSettings do
  @moduledoc """
  Schema for the `tenant_llm_settings` table — a tenant's BYO Anthropic
  configuration (Epic 28 residual, #179).

  Each tenant has at most ONE row (unique `tenant_id`). It holds the tenant's own
  Anthropic API key, encrypted at rest via Cloak (`Loopctl.Vault.Binary`,
  AES-256-GCM) and `redact: true` so it never appears in `inspect/1` or log output.
  The three per-operation model fields let a tenant pick a different model for
  extraction, classification, and merge; each is a free-form, plausible model id
  (NOT restricted to an allow-list) or NULL to fall back to the server default.

  ## Security invariants

  - `api_key` is NEVER placed in a `cast/3` list — it is set programmatically via
    `put_change/3` so a stray param can't overwrite it and it never lands in the
    changeset's `params` echoed by error rendering.
  - `api_key` is `redact: true` — `inspect(%TenantLlmSettings{})` shows
    `**redacted**`.
  - No serializer ever returns the key (only `has_api_key?` + a last-4 hint).
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

    timestamps()
  end

  @model_fields [:extraction_model, :classification_model, :merge_model]

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
  Sets the encrypted `api_key` on a changeset via `put_change/3` (never `cast`),
  validating it's a non-empty, bounded string. A `nil`/absent value leaves the
  existing key untouched; a blank string is rejected.
  """
  @spec put_api_key(Ecto.Changeset.t(), String.t() | nil) :: Ecto.Changeset.t()
  def put_api_key(changeset, nil), do: changeset

  def put_api_key(changeset, api_key) when is_binary(api_key) do
    trimmed = String.trim(api_key)

    cond do
      trimmed == "" ->
        add_error(changeset, :api_key, "must not be blank")

      String.length(trimmed) > @max_api_key_length ->
        add_error(changeset, :api_key, "is too long (max #{@max_api_key_length} characters)")

      true ->
        put_change(changeset, :api_key, trimmed)
    end
  end

  def put_api_key(changeset, _other),
    do: add_error(changeset, :api_key, "must be a string")

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
