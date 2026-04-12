defmodule Loopctl.Secrets do
  @moduledoc """
  Facade for secret storage. Delegates to the configured adapter.

  Production: `Loopctl.Secrets.FlyAdapter` (Fly.io GraphQL API).
  Tests: `Loopctl.MockSecrets` (Mox stub).
  """

  @doc "Read a secret by name."
  @spec get(String.t()) :: {:ok, binary()} | {:error, term()}
  def get(name), do: adapter().get(name)

  @doc "Write or overwrite a secret."
  @spec set(String.t(), binary()) :: :ok | {:error, term()}
  def set(name, value), do: adapter().set(name, value)

  @doc "Delete a secret."
  @spec delete(String.t()) :: :ok | {:error, term()}
  def delete(name), do: adapter().delete(name)

  @doc "Build the Fly secret name for a tenant's audit key."
  @spec audit_key_secret_name(String.t()) :: String.t()
  def audit_key_secret_name(slug) when is_binary(slug) do
    upper = slug |> String.upcase() |> String.replace("-", "_")
    "TENANT_AUDIT_KEY_#{upper}"
  end

  defp adapter do
    Application.get_env(:loopctl, :secrets_adapter, Loopctl.Secrets.FlyAdapter)
  end
end
