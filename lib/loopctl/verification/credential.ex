defmodule Loopctl.Verification.Credential do
  @moduledoc """
  The ONE credential seam every forge call reads GitHub through (US-26.4.6, #936): the merge
  gate, story verification, post-deploy verification, the thread checkpoint reads, the issue
  closer and the thread issue links. Each asks here per tenant AND repository, and makes no
  request when it answers `{:error, :credential_unavailable}`. The thread-mode merge, which
  loopctl's GitHub App writes, asks here too before it opens an App session
  (`Loopctl.Delivery.MergeExecutor`): an operator credential licenses it, and a tenant token
  licenses it only when that token's owner can push to the repository.

  ## Why a (tenant, repository) pair has to be named before anything is read

  An intake source names a repository, and enrolment does not prove the tenant controls it.
  Reading it with the operator's `GITHUB_TOKEN`, which can read every private repository the
  operator can, would make loopctl a cross-tenant oracle: enrol somebody else's private
  repository and read back whether a commit exists there, what its CI said and which files a
  change touched. So the credential answered here is, in order:

  1. `kind: :tenant_token`, the tenant's own token (`Loopctl.Forge`), for any repository. It
     can read only what the tenant already can, so it discloses nothing.
  2. `kind: :operator_token`, only for a (tenant, repository) pair the operator named in
     `VERIFICATION_OPERATOR_TOKEN_TENANTS` (`Loopctl.Verification.OperatorCredential`).
  3. Nothing.

  ## What the credential carries

  `repo`, a `Loopctl.Delivery.ForgeRepo` holding the repository and the token to use, which is
  what every `Loopctl.Delivery.PullRequestSource` callback takes. A caller cannot hand the
  forge a bare repository name, so the only way to a request runs through this seam.

  `any_for_tenant?/1` is the cheap question story verification asks before it reads anything
  of the story: `false` means `for_read/2` answers `credential_unavailable` whatever the
  repository.
  """

  alias Loopctl.Delivery.ForgeRepo

  @enforce_keys [:kind, :repo]
  defstruct [:kind, :repo]

  @type t :: %__MODULE__{kind: :tenant_token | :operator_token, repo: ForgeRepo.t()}

  @doc """
  The credential a forge call on `repo_full_name` (`owner/name`, the intake source's) makes
  on behalf of `tenant_id`, or none.
  """
  @callback for_read(tenant_id :: Ecto.UUID.t(), repo_full_name :: String.t()) ::
              {:ok, t()} | {:error, :credential_unavailable}

  @doc """
  Whether `tenant_id` could get a credential for ANY repository. A cheap check the worker
  makes before it reads anything of the story: `false` means `for_read/2` answers
  `credential_unavailable` whatever the repository.
  """
  @callback any_for_tenant?(tenant_id :: Ecto.UUID.t()) :: boolean()

  @doc "Resolves through the configured implementation (`:verification_credential`)."
  @spec for_read(Ecto.UUID.t(), String.t()) :: {:ok, t()} | {:error, :credential_unavailable}
  def for_read(tenant_id, repo_full_name), do: impl().for_read(tenant_id, repo_full_name)

  @doc """
  The `Loopctl.Delivery.ForgeRepo` to call the forge with, or `{:error,
  :credential_unavailable}`: `for_read/2` for callers that want only the repository.
  """
  @spec repo(Ecto.UUID.t(), String.t()) ::
          {:ok, ForgeRepo.t()} | {:error, :credential_unavailable}
  def repo(tenant_id, repo_full_name) do
    case for_read(tenant_id, repo_full_name) do
      {:ok, %__MODULE__{repo: %ForgeRepo{} = repo}} -> {:ok, repo}
      {:error, :credential_unavailable} = error -> error
    end
  end

  @doc "Resolves through the configured implementation (`:verification_credential`)."
  @spec any_for_tenant?(Ecto.UUID.t()) :: boolean()
  def any_for_tenant?(tenant_id), do: impl().any_for_tenant?(tenant_id)

  defp impl do
    Application.get_env(
      :loopctl,
      :verification_credential,
      Loopctl.Verification.ForgeCredential
    )
  end
end
