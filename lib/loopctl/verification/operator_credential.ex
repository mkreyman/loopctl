defmodule Loopctl.Verification.OperatorCredential do
  @moduledoc """
  `Loopctl.Verification.Credential` over the operator's `GITHUB_TOKEN`, lent ONLY for the
  (tenant, repository) pairs the operator named in `VERIFICATION_OPERATOR_TOKEN_TENANTS`
  (`config :loopctl, :verification_operator_token_tenants`), each entry
  `<tenant_uuid>:<owner>/<repo>`. Default: nothing, so a deployment that sets nothing reads no
  tenant's repository with its own token. See the `Credential` moduledoc for why.

  A PAIR, not a tenant: naming a tenant alone would let it enrol any OTHER repository the
  operator's token can read and have verification read it. A tenant named for `acme/one` that
  enrols `acme/two` gets no credential for `acme/two`.

  Both halves match case-insensitively (GitHub names are). An entry whose tenant half is not a
  UUID, or whose repository half is not `owner/name`, can never match and is dropped.
  """

  @behaviour Loopctl.Verification.Credential

  alias Loopctl.Intake.Source
  alias Loopctl.Verification.Credential

  @impl true
  def for_read(tenant_id, repo_full_name)
      when is_binary(tenant_id) and is_binary(repo_full_name) do
    if {String.downcase(tenant_id), String.downcase(repo_full_name)} in allowlist() do
      {:ok, %Credential{kind: :operator_token, token: System.get_env("GITHUB_TOKEN")}}
    else
      {:error, :credential_unavailable}
    end
  end

  def for_read(_tenant_id, _repo_full_name), do: {:error, :credential_unavailable}

  @doc """
  The (tenant, repository) pairs the operator token may read for, normalised to lower case.
  Public for the operator's check.
  """
  @spec allowlist() :: [{String.t(), String.t()}]
  def allowlist do
    :loopctl
    |> Application.get_env(:verification_operator_token_tenants, [])
    |> List.wrap()
    |> Enum.flat_map(&parse_entry/1)
  end

  defp parse_entry(entry) when is_binary(entry) do
    with [tenant, repo] <- String.split(entry, ":", parts: 2),
         tenant = tenant |> String.trim() |> String.downcase(),
         repo = String.trim(repo),
         {:ok, _uuid} <- Ecto.UUID.cast(tenant),
         true <- Regex.match?(Source.repo_format(), repo) do
      [{tenant, String.downcase(repo)}]
    else
      _malformed -> []
    end
  end

  defp parse_entry(_entry), do: []
end
