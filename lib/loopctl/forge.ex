defmodule Loopctl.Forge do
  @moduledoc """
  A tenant's own GitHub token (#936), which every forge call made on that tenant's behalf
  authenticates with: the merge gate, story verification, post-deploy verification, the
  thread checkpoint reads and the issue closer.

  ## Why the tenant's token

  loopctl reads the repository a tenant enrolled in an intake source, and enrolment does not
  prove the tenant controls it. Read with the operator's `GITHUB_TOKEN`, which can see every
  private repository the operator can, that made loopctl a cross-tenant oracle: enrol another
  party's private repository and read back whether a commit exists there, what its CI said,
  and which files a change touched. Read with the tenant's own token, a tenant learns nothing
  its token could not already read, so there is no ownership to prove and nothing for loopctl
  to check beyond using the right token.

  Which credential a (tenant, repository) gets is decided in ONE place,
  `Loopctl.Verification.Credential.for_read/2`: this token when the tenant has set one,
  otherwise the operator's token for the pairs the operator named in
  `VERIFICATION_OPERATOR_TOKEN_TENANTS`, otherwise none.

  ## Storage

  One row per tenant (`Loopctl.Forge.TenantCredential`), the token encrypted at rest and never
  returned: `view/1` says whether one is set and shows its last four characters. Setting and
  clearing are audited without the value. Reads and writes use AdminRepo with an explicit
  `tenant_id` predicate, because the callers include Oban workers with no tenant session.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias Loopctl.AdminRepo
  alias Loopctl.Audit
  alias Loopctl.Forge.TenantCredential

  @doc "The tenant's token, decrypted, or `:none`."
  @spec token(Ecto.UUID.t()) :: {:ok, String.t()} | :none
  def token(tenant_id) when is_binary(tenant_id) do
    with {:ok, tenant_id} <- Ecto.UUID.cast(tenant_id),
         %TenantCredential{token: token} when is_binary(token) and token != "" <- load(tenant_id) do
      {:ok, token}
    else
      _none -> :none
    end
  end

  def token(_tenant_id), do: :none

  @doc "Whether the tenant has a token set."
  @spec token?(Ecto.UUID.t()) :: boolean()
  def token?(tenant_id), do: token(tenant_id) != :none

  @doc """
  Sets or replaces the tenant's token. `actor_id` is the calling API key's id, recorded on the
  audit entry with the action and never with the value.
  """
  @spec set_token(Ecto.UUID.t(), term(), Ecto.UUID.t() | nil) ::
          {:ok, map()} | {:error, Ecto.Changeset.t()}
  def set_token(tenant_id, token, actor_id) when is_binary(tenant_id) do
    existing = load(tenant_id)
    changeset = TenantCredential.token_changeset(existing || new(tenant_id), token)
    action = if existing, do: "github_credential.replaced", else: "github_credential.set"

    Multi.new()
    |> Multi.insert_or_update(:credential, changeset)
    |> Audit.log_in_multi(:audit, fn %{credential: credential} ->
      audit_attrs(tenant_id, credential.id, action, actor_id)
    end)
    |> AdminRepo.transaction()
    |> case do
      {:ok, %{credential: credential}} -> {:ok, view(credential)}
      {:error, :credential, changeset, _changes} -> {:error, changeset}
    end
  end

  @doc """
  Removes the tenant's token. Every forge call for the tenant then falls back to what the
  operator lent it, which by default is nothing. `{:ok, view}` whether or not one was set, so
  a retried clear is not an error.
  """
  @spec clear_token(Ecto.UUID.t(), Ecto.UUID.t() | nil) :: {:ok, map()}
  def clear_token(tenant_id, actor_id) when is_binary(tenant_id) do
    case load(tenant_id) do
      nil ->
        {:ok, view(nil)}

      %TenantCredential{} = credential ->
        {:ok, _changes} =
          Multi.new()
          |> Multi.delete(:credential, credential)
          |> Audit.log_in_multi(:audit, fn _changes ->
            audit_attrs(tenant_id, credential.id, "github_credential.cleared", actor_id)
          end)
          |> AdminRepo.transaction()

        {:ok, view(nil)}
    end
  end

  @doc "What may be shown about the tenant's token: whether it is set, its last four, and when."
  @spec view(Ecto.UUID.t() | TenantCredential.t() | nil) :: map()
  def view(tenant_id) when is_binary(tenant_id), do: tenant_id |> load() |> view()

  def view(nil), do: %{has_token: false, token_hint: nil, updated_at: nil}

  def view(%TenantCredential{token: token, updated_at: updated_at}) do
    %{has_token: true, token_hint: hint(token), updated_at: updated_at}
  end

  defp hint(token) when is_binary(token) and byte_size(token) >= 8,
    do: "…" <> String.slice(token, -4, 4)

  defp hint(_short), do: "…"

  defp load(tenant_id) do
    AdminRepo.one(from c in TenantCredential, where: c.tenant_id == ^tenant_id)
  end

  defp new(tenant_id), do: %TenantCredential{tenant_id: tenant_id}

  defp audit_attrs(tenant_id, entity_id, action, actor_id) do
    %{
      tenant_id: tenant_id,
      entity_type: "github_credential",
      entity_id: entity_id,
      action: action,
      actor_type: "api_key",
      actor_id: actor_id,
      actor_label: "github_credential",
      new_state: %{}
    }
  end
end
