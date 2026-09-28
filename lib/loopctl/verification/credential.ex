defmodule Loopctl.Verification.Credential do
  @moduledoc """
  The ONE credential seam story verification reads GitHub through (US-26.4.6, AC-26.4.6.8):
  every CI read asks it first, per tenant AND repository, and reads nothing when it answers
  `{:error, :credential_unavailable}`.

  ## Why a (tenant, repository) pair has to be named before anything is read

  An intake source names a repository, and enrolment does not prove the tenant controls it.
  The only credential loopctl holds is the operator's `GITHUB_TOKEN`, which can read every
  private repository the operator can. Reading with it on behalf of any tenant that enrolled
  a repository would make verification a cross-tenant oracle: enrol somebody else's private
  repository, request a verification, and read back whether a commit exists there and what
  its CI said. Naming the tenant alone is not enough for the same reason: a trusted tenant
  could enrol a repository that is not its own. So, until a per-tenant credential exists
  (#915, "Needs Mark"), the operator token is lent only for the (tenant, repository) pairs the
  operator named (`Loopctl.Verification.OperatorCredential`,
  `VERIFICATION_OPERATOR_TOKEN_TENANTS`), and every other read records
  `credential_unavailable`.

  The worker asks twice. `any_for_tenant?/1` first, before it reads anything of the story, so
  a tenant with no entry at all costs no database read; then `for_read/2` for the pair, once
  the story's repository is known.

  ## What the credential carries

  `kind: :operator_token` is the only kind today, and it carries NO TOKEN. This seam LICENSES
  a read; it does not supply the secret the read authenticates with. The CI reads go through
  the merge gate's forge adapter (`Loopctl.Delivery.GitHubPullRequestSource`), which reads the
  operator's `GITHUB_TOKEN` itself, so the token never leaves that adapter. Carrying a
  per-tenant token (#915) is therefore not a change to this module alone: the
  `Loopctl.Delivery.PullRequestSource` callbacks verification calls (`compare/3`,
  `check_evidence/3`, `resolve_commit/2`) have to take one, which they do not today.
  """

  @enforce_keys [:kind]
  defstruct [:kind]

  @type t :: %__MODULE__{kind: :operator_token}

  @doc """
  The credential verification may read `repo_full_name` (`owner/name`, the intake source's)
  with on behalf of `tenant_id`, or none.
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

  @doc "Resolves through the configured implementation (`:verification_credential`)."
  @spec any_for_tenant?(Ecto.UUID.t()) :: boolean()
  def any_for_tenant?(tenant_id), do: impl().any_for_tenant?(tenant_id)

  defp impl do
    Application.get_env(
      :loopctl,
      :verification_credential,
      Loopctl.Verification.OperatorCredential
    )
  end
end
