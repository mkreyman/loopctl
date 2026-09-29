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

  @doc "The longest token accepted, in characters: the ONE value the API docs cite too."
  @spec max_token_length() :: pos_integer()
  def max_token_length, do: @max_token_length

  schema "tenant_github_credentials" do
    tenant_field()
    field :token, Loopctl.Vault.Binary, redact: true

    timestamps()
  end

  @doc """
  Sets the token via `put_change/3`, trimmed. Blank, over #{@max_token_length} characters, or
  carrying any character outside GitHub's token alphabet (`A-Z a-z 0-9 _`, the shape of
  `ghp_…`, `github_pat_…`, `ghs_…`) is refused: a non-breaking or zero-width space, a control
  byte or any other paste accident would otherwise be stored and fail on the first forge
  call, far from here — as a 401, or as a header-encoding error that reads as transient.
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

      not String.match?(trimmed, ~r/\A[A-Za-z0-9_]+\z/) ->
        add_error(changeset, :token, "must contain only letters, digits and underscores")

      true ->
        changeset
        |> put_change(:token, trimmed)
        |> unique_constraint(:tenant_id)
    end
  end

  def token_changeset(credential, _token),
    do: credential |> change() |> add_error(:token, "must be a string")
end
