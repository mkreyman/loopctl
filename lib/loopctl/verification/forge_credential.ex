defmodule Loopctl.Verification.ForgeCredential do
  @moduledoc """
  The configured `Loopctl.Verification.Credential` (#936): the tenant's own token
  (`Loopctl.Forge`) for any repository, otherwise whatever the operator lent the (tenant,
  repository) pair (`Loopctl.Verification.OperatorCredential`), otherwise none. See the
  `Credential` moduledoc for why the order is the whole of the security argument.

  A tenant with a token of its own never falls back to the operator's, even for a pair the
  operator named: its token failing on a repository is an answer about that tenant's access,
  and reading the repository with a broader token would override it.
  """

  @behaviour Loopctl.Verification.Credential

  alias Loopctl.Delivery.ForgeRepo
  alias Loopctl.Forge
  alias Loopctl.Verification.Credential
  alias Loopctl.Verification.OperatorCredential

  @impl true
  def for_read(tenant_id, repo_full_name)
      when is_binary(tenant_id) and is_binary(repo_full_name) do
    case Forge.token(tenant_id) do
      {:ok, token} ->
        {:ok, %Credential{kind: :tenant_token, repo: ForgeRepo.tenant(repo_full_name, token)}}

      :none ->
        OperatorCredential.for_read(tenant_id, repo_full_name)
    end
  end

  def for_read(_tenant_id, _repo_full_name), do: {:error, :credential_unavailable}

  @impl true
  def any_for_tenant?(tenant_id) when is_binary(tenant_id),
    do: Forge.token?(tenant_id) or OperatorCredential.any_for_tenant?(tenant_id)

  def any_for_tenant?(_tenant_id), do: false
end
