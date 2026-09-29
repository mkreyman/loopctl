defmodule Loopctl.Forge do
  @moduledoc """
  A tenant's own GitHub token (#936), which every forge call made on that tenant's behalf
  authenticates with: the merge gate, story verification, post-deploy verification, the
  thread checkpoint reads, the issue closer and thread issue links. The one forge WRITE it
  does not authenticate is the thread-mode merge, which loopctl's GitHub App performs
  (`Loopctl.Delivery.MergeExecutor`); that write is licensed only for a pair the operator
  named, never by a tenant's own token.

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

  @doc "Whether the tenant has a token set: one indexed existence check, nothing decrypted."
  @spec token?(Ecto.UUID.t()) :: boolean()
  def token?(tenant_id) when is_binary(tenant_id) do
    case Ecto.UUID.cast(tenant_id) do
      {:ok, id} -> AdminRepo.exists?(from c in TenantCredential, where: c.tenant_id == ^id)
      :error -> false
    end
  end

  def token?(_tenant_id), do: false

  @doc """
  Sets or replaces the tenant's token. `actor_id` is the calling API key's id, recorded on the
  audit entry with the action and never with the value.

  One upsert on the `tenant_id` unique index, so two concurrent first-time sets, or a set racing
  a clear, each land as a whole write instead of one of them failing on a row the other moved.
  Whether it SET or REPLACED is read from the row the write returns: a replaced row keeps its
  `inserted_at`.
  """
  @spec set_token(Ecto.UUID.t(), term(), Ecto.UUID.t() | nil) ::
          {:ok, map()} | {:error, Ecto.Changeset.t()} | {:error, term()}
  def set_token(tenant_id, token, actor_id) when is_binary(tenant_id) do
    changeset = TenantCredential.token_changeset(%TenantCredential{tenant_id: tenant_id}, token)

    Multi.new()
    |> Multi.insert(:credential, changeset,
      on_conflict: {:replace, [:token, :updated_at]},
      conflict_target: :tenant_id,
      returning: true
    )
    |> Audit.log_in_multi(:audit, fn %{credential: credential} ->
      action =
        if credential.inserted_at == credential.updated_at,
          do: "github_credential.set",
          else: "github_credential.replaced"

      audit_attrs(tenant_id, credential.id, action, actor_id)
    end)
    |> AdminRepo.transaction()
    |> case do
      {:ok, %{credential: credential}} -> {:ok, view(credential)}
      {:error, :credential, %Ecto.Changeset{} = changeset, _changes} -> {:error, changeset}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  @doc """
  Removes the tenant's token. Every forge call for the tenant then falls back to what the
  operator lent it, which by default is nothing. `{:ok, view}` whether or not one was set, so
  a retried or concurrent clear is not an error: the delete is by `tenant_id`, and only the
  call that actually removed a row writes the audit entry.
  """
  @spec clear_token(Ecto.UUID.t(), Ecto.UUID.t() | nil) :: {:ok, map()} | {:error, term()}
  def clear_token(tenant_id, actor_id) when is_binary(tenant_id) do
    Multi.new()
    |> Multi.delete_all(
      :deleted,
      from(c in TenantCredential, where: c.tenant_id == ^tenant_id, select: c.id)
    )
    |> Multi.merge(fn
      %{deleted: {0, _ids}} ->
        Multi.new()

      %{deleted: {_count, [id | _]}} ->
        Audit.log_in_multi(Multi.new(), :audit, fn _changes ->
          audit_attrs(tenant_id, id, "github_credential.cleared", actor_id)
        end)
    end)
    |> AdminRepo.transaction()
    |> case do
      {:ok, _changes} -> {:ok, view(nil)}
      {:error, _step, reason, _changes} -> {:error, reason}
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
