defmodule Loopctl.Verification.Credential do
  @moduledoc """
  The ONE credential seam story verification reads GitHub through (US-26.4.6, AC-26.4.6.8):
  every CI read and the local fallback's clone ask it first, per tenant, and read nothing
  when it answers `{:error, :credential_unavailable}`.

  ## Why a tenant has to be named before anything is read

  An intake source names a repository, and enrolment does not prove the tenant controls it.
  The only credential loopctl holds is the operator's `GITHUB_TOKEN`, which can read every
  private repository the operator can. Reading with it on behalf of any tenant that enrolled
  a repository would make verification a cross-tenant oracle: enrol somebody else's private
  repository, request a verification, and read back whether a commit exists there and what
  its CI said. So, until a per-tenant credential exists (#915, "Needs Mark"), the operator
  token is lent only to the tenants the operator named (`Loopctl.Verification.OperatorCredential`,
  `VERIFICATION_OPERATOR_TOKEN_TENANTS`), and every other tenant records
  `credential_unavailable`.

  ## What the credential carries

  `kind: :operator_token` is the only kind today. The CI reads go through the merge gate's
  forge adapter (`Loopctl.Delivery.GitHubPullRequestSource`), which authenticates with the
  same `GITHUB_TOKEN` itself, so for those the credential is what LICENSES the read. The
  clone has no adapter of its own and takes the token from `token` (`git_env/1`). The token
  is never inspected into a log: `Inspect` omits it.
  """

  @derive {Inspect, except: [:token]}
  @enforce_keys [:kind]
  defstruct [:kind, :token]

  @type t :: %__MODULE__{kind: :operator_token, token: String.t() | nil}

  @doc "The credential verification may read `tenant_id`'s repository with, or none."
  @callback for_tenant(tenant_id :: Ecto.UUID.t()) ::
              {:ok, t()} | {:error, :credential_unavailable}

  @doc "Resolves through the configured implementation (`:verification_credential`)."
  @spec for_tenant(Ecto.UUID.t()) :: {:ok, t()} | {:error, :credential_unavailable}
  def for_tenant(tenant_id), do: impl().for_tenant(tenant_id)

  defp impl do
    Application.get_env(
      :loopctl,
      :verification_credential,
      Loopctl.Verification.OperatorCredential
    )
  end

  @doc """
  The environment a `git` subprocess needs to fetch over HTTPS from github.com with the
  credential, and nothing when it has no token (an anonymous clone of a public repository).

  Passed in the ENVIRONMENT (`GIT_CONFIG_COUNT`/`GIT_CONFIG_KEY_n`/`GIT_CONFIG_VALUE_n`), never
  on the command line, where any user on the host could read it in the process list. The
  header is scoped to `https://github.com/`, so it is never sent to another host, redirects
  are refused, and git never prompts for credentials it was not given.
  """
  @spec git_env(t()) :: [{String.t(), String.t()}]
  def git_env(%__MODULE__{token: token}) do
    base = [{"GIT_TERMINAL_PROMPT", "0"}]

    case token && String.trim(token) do
      blank when blank in [nil, ""] ->
        base ++
          [
            {"GIT_CONFIG_COUNT", "1"},
            {"GIT_CONFIG_KEY_0", "http.followRedirects"},
            {"GIT_CONFIG_VALUE_0", "false"}
          ]

      token ->
        basic = Base.encode64("x-access-token:" <> token)

        base ++
          [
            {"GIT_CONFIG_COUNT", "2"},
            {"GIT_CONFIG_KEY_0", "http.followRedirects"},
            {"GIT_CONFIG_VALUE_0", "false"},
            {"GIT_CONFIG_KEY_1", "http.https://github.com/.extraheader"},
            {"GIT_CONFIG_VALUE_1", "AUTHORIZATION: basic " <> basic}
          ]
    end
  end
end
