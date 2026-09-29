defmodule Loopctl.Forge.TenantCredential do
  @moduledoc """
  Schema for `tenant_github_credentials`: a tenant's own GitHub token (#936). At most one row
  per tenant.

  The token is encrypted at rest (`Loopctl.Vault.Binary`, AES-256-GCM), `redact: true`, never
  cast from params and never serialised: `Loopctl.Forge.view/1` returns only whether one is
  set and its last four characters.
  """

  use Loopctl.Schema

  @type t :: %__MODULE__{}

  @max_token_length 500

  schema "tenant_github_credentials" do
    tenant_field()
    field :token, Loopctl.Vault.Binary, redact: true

    timestamps()
  end

  @doc """
  Sets the token via `put_change/3`, trimmed. Blank, over #{@max_token_length} characters, or
  carrying whitespace inside is refused: a GitHub token is one opaque word, and one with a
  space in it is a paste accident that would otherwise fail on the first read, far from here.
  """
  @spec token_changeset(t(), term()) :: Ecto.Changeset.t()
  def token_changeset(credential, token) when is_binary(token) do
    trimmed = String.trim(token)
    changeset = change(credential)

    cond do
      trimmed == "" ->
        add_error(changeset, :token, "must not be blank")

      String.length(trimmed) > @max_token_length ->
        add_error(changeset, :token, "is too long (max #{@max_token_length} characters)")

      String.match?(trimmed, ~r/\s/) ->
        add_error(changeset, :token, "must not contain whitespace")

      true ->
        changeset
        |> put_change(:token, trimmed)
        |> unique_constraint(:tenant_id)
    end
  end

  def token_changeset(credential, _token),
    do: credential |> change() |> add_error(:token, "must be a string")
end
