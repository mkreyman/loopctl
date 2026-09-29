defmodule Loopctl.Delivery.ForgeRepo do
  @moduledoc """
  A repository together with the credential every forge call on it authenticates with (#936).

  `Loopctl.Delivery.PullRequestSource` takes one of these, never a bare `owner/name`, so no
  forge read or write can happen without a credential having been chosen for it first. The one
  place that chooses is `Loopctl.Verification.Credential.for_read/2`, per (tenant, repository):

  - `{:token, token}`: the tenant's own GitHub token (`Loopctl.Forge`). A tenant reading with
    its own token can learn nothing its token could not already read, which is what closes the
    cross-tenant disclosure #936 describes.
  - `:operator`: the operator's `GITHUB_TOKEN`, lent only for the (tenant, repository) pairs
    named in `VERIFICATION_OPERATOR_TOKEN_TENANTS` (`Loopctl.Verification.OperatorCredential`).

  The token never appears in `inspect/1`, so a struct in a log line or a crash report carries
  the repository name and the credential's kind only.
  """

  @enforce_keys [:full_name, :auth]
  defstruct [:full_name, :auth]

  @type auth :: :operator | {:token, String.t()}
  @type t :: %__MODULE__{full_name: String.t(), auth: auth()}

  @doc "The repository read with the operator's `GITHUB_TOKEN`."
  @spec operator(String.t()) :: t()
  def operator(full_name), do: %__MODULE__{full_name: full_name, auth: :operator}

  @doc "The repository read with a tenant's own token."
  @spec tenant(String.t(), String.t()) :: t()
  def tenant(full_name, token) when is_binary(token),
    do: %__MODULE__{full_name: full_name, auth: {:token, token}}

  @doc "The token a request authenticates with: the tenant's, or the operator's from the environment."
  @spec token(t()) :: String.t() | nil
  def token(%__MODULE__{auth: {:token, token}}), do: token
  def token(%__MODULE__{auth: :operator}), do: System.get_env("GITHUB_TOKEN")

  defimpl Inspect do
    def inspect(%{full_name: full_name, auth: auth}, _opts) do
      kind = if auth == :operator, do: "operator", else: "tenant"
      "#Loopctl.Delivery.ForgeRepo<#{full_name} (#{kind})>"
    end
  end
end
