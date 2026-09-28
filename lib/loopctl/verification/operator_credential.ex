defmodule Loopctl.Verification.OperatorCredential do
  @moduledoc """
  `Loopctl.Verification.Credential` over the operator's `GITHUB_TOKEN`, lent ONLY to the
  tenants the operator named in `VERIFICATION_OPERATOR_TOKEN_TENANTS`
  (`config :loopctl, :verification_operator_token_tenants`). Default: nobody, so a
  deployment that sets nothing reads no tenant's repository with its own token. See the
  `Credential` moduledoc for why.

  An entry that is not a UUID can never match a tenant id and is dropped; case is ignored.
  """

  @behaviour Loopctl.Verification.Credential

  alias Loopctl.Verification.Credential

  @impl true
  def for_tenant(tenant_id) when is_binary(tenant_id) do
    if String.downcase(tenant_id) in allowlist() do
      {:ok, %Credential{kind: :operator_token, token: System.get_env("GITHUB_TOKEN")}}
    else
      {:error, :credential_unavailable}
    end
  end

  def for_tenant(_tenant_id), do: {:error, :credential_unavailable}

  @doc "The tenants the operator token may read for, normalised. Public for the operator's check."
  @spec allowlist() :: [String.t()]
  def allowlist do
    :loopctl
    |> Application.get_env(:verification_operator_token_tenants, [])
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&(&1 |> String.trim() |> String.downcase()))
    |> Enum.filter(&match?({:ok, _}, Ecto.UUID.cast(&1)))
  end
end
